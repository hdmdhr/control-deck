import ApplicationServices
import AppKit
import AudioToolbox
@preconcurrency import AVFoundation
@preconcurrency import FluidAudio
import Foundation
import OSLog
@preconcurrency import WhisperKit

enum LocalSpeechTranscriptionError: LocalizedError {
    case accessibilityRequired
    case microphonePermissionDenied
    case noTextField
    case modelNotReady(String)
    case microphoneUnavailable
    case recordingUnavailable(String)
    case noSpeechDetected
    case targetUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            String(localized: "Accessibility is required to insert dictated text", bundle: AppResources.localizationBundle)
        case .microphonePermissionDenied:
            String(localized: "Enable ControlDeck in Privacy & Security → Microphone", bundle: AppResources.localizationBundle)
        case .noTextField:
            String(localized: "Focus the app where dictated text should be inserted", bundle: AppResources.localizationBundle)
        case let .modelNotReady(name):
            String(localized: "\(name) is not ready yet", bundle: AppResources.localizationBundle)
        case .microphoneUnavailable:
            String(localized: "The selected microphone is unavailable", bundle: AppResources.localizationBundle)
        case let .recordingUnavailable(message):
            String(localized: "Local transcription could not start: \(message)", bundle: AppResources.localizationBundle)
        case .noSpeechDetected:
            String(localized: "No speech was detected", bundle: AppResources.localizationBundle)
        case .targetUnavailable:
            String(localized: "The original text field is no longer available", bundle: AppResources.localizationBundle)
        }
    }
}

struct LocalSpeechTranscriptionResult {
    let text: String
    let insertionMethod: AppleSpeechTranscriptionResult.InsertionMethod
    let engineUsed: GeneralDictationEngine
    let usedFallback: Bool
}

@MainActor
final class LocalSpeechTranscriptionService: ObservableObject {
    private struct AudioPacket: Sendable {
        let samples: [Float]
        let sampleRate: Int32
    }

    enum ModelState: Equatable {
        case notInstalled
        case downloading
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var parakeetState: ModelState = .notInstalled
    @Published private(set) var whisperKitState: ModelState = .notInstalled
    @Published private(set) var whisperKitSmallState: ModelState =
        .notInstalled
    @Published private(set) var parakeetStatus =
        String(localized: "Parakeet EOU 120M is not downloaded", bundle: AppResources.localizationBundle)
    @Published private(set) var whisperKitStatus =
        String(localized: "WhisperKit Base English is not downloaded", bundle: AppResources.localizationBundle)
    @Published private(set) var whisperKitSmallStatus =
        String(localized: "WhisperKit Small English is not downloaded", bundle: AppResources.localizationBundle)
    @Published private(set) var whisperKitProgress: Double = 0
    @Published private(set) var whisperKitSmallProgress: Double = 0
    @Published private(set) var parakeetBytes: Int64 = 0
    @Published private(set) var whisperKitBytes: Int64 = 0
    @Published private(set) var whisperKitSmallBytes: Int64 = 0
    @Published private(set) var partialTranscript = ""
    @Published private(set) var isActive = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var audioDuration: TimeInterval = 0
    @Published private(set) var activeStatus = String(localized: "Ready", bundle: AppResources.localizationBundle)

    var onPartialTranscript: ((String) -> Void)?
    var onInputLevel: ((Float) -> Void)?

    private let worker = LocalSpeechWorker()
    private let logger = Logger(
        subsystem: "com.ianhansel.controldeck",
        category: "local-speech"
    )
    private var preparationTasks:
        [GeneralDictationEngine: Task<Void, Never>] = [:]
    private var lastLoggedDownloadPercentage:
        [GeneralDictationEngine: Int] = [:]
    private var activeEngine: GeneralDictationEngine?
    private var target: SpeechTextInsertionTarget?
    private var audioEngine: AVAudioEngine?
    private var audioContinuation:
        AsyncStream<AudioPacket>.Continuation?
    private var audioStream: AsyncStream<AudioPacket>?
    private var audioPumpTask: Task<Void, Never>?

    init() {
        removeRetiredMoonshineModel()
        refreshInstalledSizes()
    }

    var externalPCMHandler: (@Sendable ([Float], Int) -> Void)? {
        guard isActive, let audioContinuation else { return nil }
        return { samples, count in
            let safeCount = min(max(0, count), samples.count)
            guard safeCount > 0 else { return }
            audioContinuation.yield(
                AudioPacket(
                    samples: Array(samples.prefix(safeCount)),
                    sampleRate: Int32(
                        DualSenseBluetoothAudioProtocol.microphoneSampleRate
                    )
                )
            )
        }
    }

    func state(for engine: GeneralDictationEngine) -> ModelState {
        switch engine {
        case .parakeetEOU120M:
            parakeetState
        case .whisperKitBaseEnglish:
            whisperKitState
        case .whisperKitSmallEnglish:
            whisperKitSmallState
        case .appleSpeech:
            .ready
        }
    }

    func status(for engine: GeneralDictationEngine) -> String {
        switch engine {
        case .parakeetEOU120M:
            parakeetStatus
        case .whisperKitBaseEnglish:
            whisperKitStatus
        case .whisperKitSmallEnglish:
            whisperKitSmallStatus
        case .appleSpeech:
            String(localized: "Built into macOS", bundle: AppResources.localizationBundle)
        }
    }

    func installedBytes(for engine: GeneralDictationEngine) -> Int64 {
        switch engine {
        case .parakeetEOU120M:
            parakeetBytes
        case .whisperKitBaseEnglish:
            whisperKitBytes
        case .whisperKitSmallEnglish:
            whisperKitSmallBytes
        case .appleSpeech:
            0
        }
    }

    func isReady(_ engine: GeneralDictationEngine) -> Bool {
        state(for: engine) == .ready
    }

    func prepareModel(_ engine: GeneralDictationEngine) {
        guard engine != .appleSpeech,
              state(for: engine) != .ready,
              state(for: engine) != .downloading,
              state(for: engine) != .loading
        else { return }

        preparationTasks[engine]?.cancel()
        lastLoggedDownloadPercentage[engine] = nil
        let isInstalled = modelIsComplete(engine)
        setState(isInstalled ? .loading : .downloading, for: engine)
        setStatus(
            isInstalled
                ? String(localized: "Loading \(engine.engineName)", bundle: AppResources.localizationBundle)
                : String(localized: "Checking \(engine.engineName) download", bundle: AppResources.localizationBundle),
            for: engine
        )
        logger.notice(
            "\(engine.engineName, privacy: .public) preparation started"
        )
        if engine.isWhisperKit {
            setProgress(0, for: engine)
        }

        let root = modelsRoot
        preparationTasks[engine] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: true
                )
                switch engine {
                case .parakeetEOU120M:
                    self.parakeetStatus =
                        String(localized: "Downloading Parakeet EOU 120M (320 ms)", bundle: AppResources.localizationBundle)
                    try await self.worker.prepareParakeet(modelsRoot: root)
                case .whisperKitBaseEnglish,
                     .whisperKitSmallEnglish:
                    self.setStatus(
                        String(localized: "Downloading \(engine.engineName)", bundle: AppResources.localizationBundle),
                        for: engine
                    )
                    try await self.worker.prepareWhisperKit(
                        engine: engine,
                        modelsRoot: root
                    ) { [weak self] progress in
                        Task { @MainActor in
                            self?.updateDownloadProgress(
                                progress,
                                for: engine
                            )
                        }
                    }
                case .appleSpeech:
                    return
                }
                guard !Task.isCancelled else { return }
                self.refreshInstalledSizes()
                self.setState(.ready, for: engine)
                self.setStatus(String(localized: "\(engine.engineName) is ready", bundle: AppResources.localizationBundle), for: engine)
                self.logger.notice(
                    "\(engine.engineName, privacy: .public) model is ready; installedBytes=\(self.installedBytes(for: engine), privacy: .public)"
                )
                if engine.isWhisperKit {
                    self.setProgress(1, for: engine)
                }
            } catch is CancellationError {
                self.setState(.notInstalled, for: engine)
                self.setStatus(
                    String(localized: "\(engine.engineName) preparation cancelled", bundle: AppResources.localizationBundle),
                    for: engine
                )
            } catch {
                let message = error.localizedDescription
                self.setState(.failed(message), for: engine)
                self.setStatus(
                    String(localized: "\(engine.engineName) could not load: \(message)", bundle: AppResources.localizationBundle),
                    for: engine
                )
                self.logger.error(
                    "\(engine.engineName, privacy: .public) preparation failed: \(message, privacy: .public)"
                )
            }
        }
    }

    @discardableResult
    func begin(
        engine: GeneralDictationEngine,
        inputDeviceID: AudioObjectID?,
        usesExternalPCM: Bool,
        target: SpeechTextInsertionTarget? = nil,
        contextualStrings: [String] = [],
        completion: @escaping (
            Result<Void, LocalSpeechTranscriptionError>
        ) -> Void
    ) -> Bool {
        guard engine != .appleSpeech else {
            completion(
                .failure(.recordingUnavailable(String(localized: "invalid local engine", bundle: AppResources.localizationBundle)))
            )
            return false
        }
        guard isReady(engine) else {
            prepareModel(engine)
            completion(.failure(.modelNotReady(engine.label)))
            return false
        }
        guard !isActive else {
            completion(.failure(.recordingUnavailable(String(localized: "already active", bundle: AppResources.localizationBundle))))
            return false
        }
        guard AXIsProcessTrusted() else {
            completion(.failure(.accessibilityRequired))
            return false
        }
        guard let target = target ?? SpeechTextInsertionTarget.capture() else {
            completion(.failure(.noTextField))
            return false
        }

        activeEngine = engine
        self.target = target
        partialTranscript = ""
        inputLevel = 0
        audioDuration = 0
        activeStatus = String(localized: "Preparing \(engine.engineName)", bundle: AppResources.localizationBundle)
        configureAudioStream()
        isActive = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !usesExternalPCM {
                let hasPermission =
                    await self.requestMicrophonePermission()
                if !hasPermission {
                    self.clearActiveSession()
                    completion(.failure(.microphonePermissionDenied))
                    return
                }
            }
            do {
                try await self.worker.start(
                    engine: engine,
                    contextualStrings: contextualStrings
                ) {
                    [weak self] text in
                    Task { @MainActor in
                        guard let self, self.isActive else { return }
                        self.partialTranscript = text
                        self.onPartialTranscript?(text)
                    }
                }
                self.startAudioPump()
                if !usesExternalPCM {
                    try self.startAudioInput(deviceID: inputDeviceID)
                }
                self.activeStatus = String(localized: "Listening", bundle: AppResources.localizationBundle)
                completion(.success(()))
            } catch {
                await self.worker.cancel()
                self.clearActiveSession()
                completion(
                    .failure(
                        .recordingUnavailable(error.localizedDescription)
                    )
                )
            }
        }
        return true
    }

    @discardableResult
    func finish(
        recordingStopped: @escaping () -> Void,
        completion: @escaping (
            Result<
                LocalSpeechTranscriptionResult,
                LocalSpeechTranscriptionError
            >
        ) -> Void
    ) -> Bool {
        guard isActive, let target else {
            completion(.failure(.recordingUnavailable(String(localized: "not active", bundle: AppResources.localizationBundle))))
            return false
        }
        stopAudioInput()
        recordingStopped()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await self.drainAudioPump()
                self.activeStatus = String(localized: "Transcribing", bundle: AppResources.localizationBundle)
                let workerResult = try await self.worker.stop()
                let metrics = await self.worker.audioMetrics()
                let text = workerResult.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.logger.notice(
                    "\(self.activeEngine?.label ?? "Local", privacy: .public) finished; transcriptCharacters=\(text.count, privacy: .public) duration=\(metrics.duration, privacy: .public) rawPeak=\(metrics.peak, privacy: .public) rawRMS=\(metrics.rms, privacy: .public) recognitionGain=\(metrics.recognitionGain, privacy: .public) droppedFrames=\(metrics.droppedFrames, privacy: .public)"
                )
                guard !text.isEmpty else {
                    self.clearActiveSession()
                    completion(.failure(.noSpeechDetected))
                    return
                }
                guard let insertion = target.insert(text) else {
                    self.clearActiveSession()
                    completion(.failure(.targetUnavailable))
                    return
                }
                self.clearActiveSession()
                completion(
                    .success(
                        LocalSpeechTranscriptionResult(
                            text: text,
                            insertionMethod: insertion,
                            engineUsed: workerResult.engineUsed,
                            usedFallback: workerResult.usedFallback
                        )
                    )
                )
            } catch {
                self.clearActiveSession()
                completion(
                    .failure(
                        .recordingUnavailable(error.localizedDescription)
                    )
                )
            }
        }
        return true
    }

    func cancel() {
        stopAudioInput()
        discardAudioPump()
        Task { await worker.cancel() }
        clearActiveSession()
    }

    func removeDownloadedModel(_ engine: GeneralDictationEngine) {
        guard engine != .appleSpeech, !isActive else { return }
        preparationTasks[engine]?.cancel()
        preparationTasks[engine] = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.worker.unload(engine)
            let location = self.modelLocation(for: engine)
            try? FileManager.default.removeItem(at: location)
            self.refreshInstalledSizes()
            self.setState(.notInstalled, for: engine)
            self.setStatus(
                String(localized: "\(engine.label) is not downloaded", bundle: AppResources.localizationBundle),
                for: engine
            )
        }
    }

    private var modelsRoot: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("ControlDeck/Models", isDirectory: true)
    }

    private func removeRetiredMoonshineModel() {
        let legacyDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent(
                "ControlDeck/Moonshine",
                isDirectory: true
            )
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: legacyDirectory)
        }
    }

    private func modelLocation(for engine: GeneralDictationEngine) -> URL {
        switch engine {
        case .parakeetEOU120M:
            modelsRoot.appendingPathComponent(
                "parakeet-eou-streaming/320ms",
                isDirectory: true
            )
        case .whisperKitBaseEnglish:
            whisperKitModelLocation(variant: "base.en")
        case .whisperKitSmallEnglish:
            whisperKitModelLocation(variant: "small.en")
        case .appleSpeech:
            modelsRoot
        }
    }

    private func whisperKitModelLocation(variant: String) -> URL {
        modelsRoot
            .appendingPathComponent(
                "WhisperKit",
                isDirectory: true
            )
            .appendingPathComponent(
                "models/argmaxinc/whisperkit-coreml",
                isDirectory: true
            )
            .appendingPathComponent(
                "openai_whisper-\(variant)",
                isDirectory: true
            )
    }

    private func refreshInstalledSizes() {
        parakeetBytes = directorySize(
            modelLocation(for: .parakeetEOU120M)
        )
        whisperKitBytes = directorySize(
            modelLocation(for: .whisperKitBaseEnglish)
        )
        whisperKitSmallBytes = directorySize(
            modelLocation(for: .whisperKitSmallEnglish)
        )
        if parakeetBytes > 0,
           modelIsComplete(.parakeetEOU120M),
           parakeetState == .notInstalled {
            parakeetStatus = String(localized: "Parakeet model found; loading is required", bundle: AppResources.localizationBundle)
        }
        if whisperKitBytes > 0,
           modelIsComplete(.whisperKitBaseEnglish),
           whisperKitState == .notInstalled {
            whisperKitStatus = String(localized: "WhisperKit model found; loading is required", bundle: AppResources.localizationBundle)
        }
        if whisperKitSmallBytes > 0,
           modelIsComplete(.whisperKitSmallEnglish),
           whisperKitSmallState == .notInstalled {
            whisperKitSmallStatus =
                String(localized: "WhisperKit Small model found; loading is required", bundle: AppResources.localizationBundle)
        }
        if whisperKitSmallBytes > 0,
           !modelIsComplete(.whisperKitSmallEnglish) {
            whisperKitSmallStatus =
                String(localized: "High Accuracy download is incomplete · select it to resume", bundle: AppResources.localizationBundle)
        }
    }

    private func modelIsComplete(
        _ engine: GeneralDictationEngine
    ) -> Bool {
        switch engine {
        case .appleSpeech:
            return true
        case .parakeetEOU120M:
            return FileManager.default.fileExists(
                atPath: modelLocation(for: engine)
                    .appendingPathComponent(
                        "streaming_encoder.mlmodelc"
                    )
                    .path
            )
        case .whisperKitBaseEnglish,
             .whisperKitSmallEnglish:
            let root = modelLocation(for: engine)
            return FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "AudioEncoder.mlmodelc/weights/weight.bin"
                ).path
            ) && FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "TextDecoder.mlmodelc/weights/weight.bin"
                ).path
            )
        }
    }

    private func directorySize(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private func setState(
        _ state: ModelState,
        for engine: GeneralDictationEngine
    ) {
        switch engine {
        case .parakeetEOU120M:
            parakeetState = state
        case .whisperKitBaseEnglish:
            whisperKitState = state
        case .whisperKitSmallEnglish:
            whisperKitSmallState = state
        case .appleSpeech:
            break
        }
    }

    private func setStatus(
        _ status: String,
        for engine: GeneralDictationEngine
    ) {
        switch engine {
        case .parakeetEOU120M:
            parakeetStatus = status
        case .whisperKitBaseEnglish:
            whisperKitStatus = status
        case .whisperKitSmallEnglish:
            whisperKitSmallStatus = status
        case .appleSpeech:
            break
        }
    }

    private func setProgress(
        _ progress: Double,
        for engine: GeneralDictationEngine
    ) {
        switch engine {
        case .whisperKitBaseEnglish:
            whisperKitProgress = progress
        case .whisperKitSmallEnglish:
            whisperKitSmallProgress = progress
        default:
            break
        }
    }

    private func updateDownloadProgress(
        _ progress: Progress,
        for engine: GeneralDictationEngine
    ) {
        let fraction = min(1, max(0, progress.fractionCompleted))
        setProgress(fraction, for: engine)
        let percentage = Int((fraction * 100).rounded())
        let expected = ByteCountFormatter.string(
            fromByteCount: engine.estimatedDownloadBytes,
            countStyle: .file
        )
        setStatus(
            String(localized: "Downloading \(engine.engineName) · \(percentage)% of about \(expected)", bundle: AppResources.localizationBundle),
            for: engine
        )
        if percentage == 1 || percentage.isMultiple(of: 10),
           lastLoggedDownloadPercentage[engine] != percentage {
            lastLoggedDownloadPercentage[engine] = percentage
            logger.notice(
                "\(engine.engineName, privacy: .public) download \(percentage, privacy: .public)%"
            )
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            true
        case .undetermined:
            await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission {
                    continuation.resume(returning: $0)
                }
            }
        case .denied:
            false
        @unknown default:
            false
        }
    }

    private func startAudioInput(
        deviceID: AudioObjectID?
    ) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if var selectedDevice = deviceID {
            guard let audioUnit = input.audioUnit else {
                throw LocalSpeechTranscriptionError.microphoneUnavailable
            }
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &selectedDevice,
                UInt32(MemoryLayout<AudioObjectID>.size)
            )
            guard status == noErr else {
                throw LocalSpeechTranscriptionError.microphoneUnavailable
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              format.channelCount > 0,
              let normalizedFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(
                      ContinuousSpeechAudioProcessor.outputSampleRate
                  ),
                  channels: 1,
                  interleaved: false
              ),
              let converter = AVAudioConverter(
                  from: format,
                  to: normalizedFormat
              )
        else {
            throw LocalSpeechTranscriptionError.microphoneUnavailable
        }
        logger.notice(
            "Local speech audio device attached; deviceID=\(deviceID ?? kAudioObjectUnknown, privacy: .public) sourceFormat=\(format.description, privacy: .public) normalizedRate=\(ContinuousSpeechAudioProcessor.outputSampleRate, privacy: .public)"
        )
        let continuation = audioContinuation
        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: format
        ) { buffer, _ in
            guard let mono = Self.convertToMonoSamples(
                buffer,
                using: converter,
                to: normalizedFormat
            ) else { return }
            continuation?.yield(
                AudioPacket(
                    samples: mono,
                    sampleRate:
                        ContinuousSpeechAudioProcessor.outputSampleRate
                )
            )
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw LocalSpeechTranscriptionError.recordingUnavailable(
                error.localizedDescription
            )
        }
        audioEngine = engine
    }

    private static func convertToMonoSamples(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> [Float]? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(
                max(
                    1,
                    ceil(Double(input.frameLength) * ratio) + 64
                )
            )
        ) else { return nil }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error,
              conversionError == nil,
              output.frameLength > 0,
              let samples = output.floatChannelData?[0]
        else { return nil }
        return Array(
            UnsafeBufferPointer(
                start: samples,
                count: Int(output.frameLength)
            )
        )
    }

    private func stopAudioInput() {
        guard let audioEngine else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        self.audioEngine = nil
    }

    private func clearActiveSession() {
        stopAudioInput()
        discardAudioPump()
        isActive = false
        activeEngine = nil
        target = nil
        partialTranscript = ""
        inputLevel = 0
        audioDuration = 0
        activeStatus = String(localized: "Ready", bundle: AppResources.localizationBundle)
    }

    private func configureAudioStream() {
        discardAudioPump()
        let pair = AsyncStream<AudioPacket>.makeStream(
            bufferingPolicy: .unbounded
        )
        audioStream = pair.stream
        audioContinuation = pair.continuation
    }

    private func startAudioPump() {
        guard audioPumpTask == nil, let audioStream else { return }
        let worker = worker
        audioPumpTask = Task {
            for await packet in audioStream {
                guard !Task.isCancelled else { break }
                let metrics = await worker.append(
                    packet.samples,
                    sampleRate: packet.sampleRate
                )
                await MainActor.run { [weak self] in
                    guard let self, self.isActive else { return }
                    self.inputLevel = metrics.level
                    self.audioDuration = metrics.duration
                    self.onInputLevel?(metrics.level)
                }
            }
        }
    }

    private func drainAudioPump() async {
        audioContinuation?.finish()
        audioContinuation = nil
        audioStream = nil
        let task = audioPumpTask
        audioPumpTask = nil
        await task?.value
    }

    private func discardAudioPump() {
        audioContinuation?.finish()
        audioContinuation = nil
        audioStream = nil
        audioPumpTask?.cancel()
        audioPumpTask = nil
    }
}

private struct LocalSpeechWorkerResult: Sendable {
    let text: String
    let engineUsed: GeneralDictationEngine
    let usedFallback: Bool
}

private actor LocalSpeechWorker {
    private let parakeetFeedFrames = 5_120
    private var parakeet: StreamingEouAsrManager?
    private var whisperKits: [GeneralDictationEngine: WhisperKit] = [:]
    private var activeEngine: GeneralDictationEngine?
    private var processingError: Error?
    private var partialHandler: (@Sendable (String) -> Void)?
    private var contextualStrings: [String] = []
    private var parakeetPending: [Float] = []
    private let audio = ContinuousSpeechAudioProcessor()

    func prepareParakeet(modelsRoot: URL) async throws {
        let manager = StreamingEouAsrManager(
            chunkSize: .ms320,
            eouDebounceMs: 960
        )
        try await manager.loadModels(to: modelsRoot)
        Self.removeParakeetSourcePackages(from: modelsRoot)
        parakeet = manager
    }

    func prepareWhisperKit(
        engine: GeneralDictationEngine,
        modelsRoot: URL,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        guard engine.isWhisperKit else {
            throw LocalSpeechTranscriptionError.recordingUnavailable(
                "invalid WhisperKit engine"
            )
        }
        let variant = engine == .whisperKitSmallEnglish
            ? "small.en"
            : "base.en"
        let downloadBase = modelsRoot.appendingPathComponent(
            "WhisperKit",
            isDirectory: true
        )
        let cachedFolder = downloadBase
            .appendingPathComponent(
                "models/argmaxinc/whisperkit-coreml",
                isDirectory: true
            )
            .appendingPathComponent(
                "openai_whisper-\(variant)",
                isDirectory: true
            )
        let hasCachedModel = FileManager.default.fileExists(
            atPath: cachedFolder.appendingPathComponent(
                "AudioEncoder.mlmodelc/weights/weight.bin"
            ).path
        ) && FileManager.default.fileExists(
            atPath: cachedFolder.appendingPathComponent(
                "TextDecoder.mlmodelc/weights/weight.bin"
            ).path
        )
        let folder = if hasCachedModel {
            cachedFolder
        } else {
            try await WhisperKit.download(
                variant: variant,
                downloadBase: downloadBase,
                progressCallback: progress
            )
        }
        let config = WhisperKitConfig(
            model: variant,
            downloadBase: downloadBase,
            modelFolder: folder.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        whisperKits[engine] = try await WhisperKit(config)
    }

    func start(
        engine: GeneralDictationEngine,
        contextualStrings: [String],
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws {
        activeEngine = engine
        processingError = nil
        partialHandler = onPartial
        self.contextualStrings = Array(contextualStrings.prefix(24))
        parakeetPending.removeAll(keepingCapacity: true)
        audio.reset()

        switch engine {
        case .parakeetEOU120M:
            guard let parakeet else {
                throw LocalSpeechTranscriptionError.modelNotReady(
                    engine.engineName
                )
            }
            await parakeet.reset()
            await parakeet.setPartialCallback(onPartial)
            await parakeet.setEouCallback(onPartial)
            parakeetPending.append(
                contentsOf: audio.allSamples()
            )
        case .whisperKitBaseEnglish,
             .whisperKitSmallEnglish:
            guard whisperKits[engine] != nil else {
                throw LocalSpeechTranscriptionError.modelNotReady(
                    engine.engineName
                )
            }
        case .appleSpeech:
            throw LocalSpeechTranscriptionError.recordingUnavailable(
                "invalid local engine"
            )
        }
    }

    @discardableResult
    func append(
        _ samples: [Float],
        sampleRate: Int32
    ) async -> SpeechAudioMetrics {
        guard !samples.isEmpty, sampleRate > 0 else {
            return audio.metrics
        }
        do {
            let normalized = try audio.append(
                samples,
                sampleRate: sampleRate
            )
            if activeEngine == .parakeetEOU120M,
               processingError == nil {
                parakeetPending.append(contentsOf: normalized)
                try await drainParakeetChunks()
            }
        } catch {
            processingError = error
        }
        return audio.metrics
    }

    func stop() async throws -> LocalSpeechWorkerResult {
        guard let requestedEngine = activeEngine else {
            throw LocalSpeechTranscriptionError.recordingUnavailable(
                "not active"
            )
        }
        defer {
            activeEngine = nil
            processingError = nil
            partialHandler = nil
            contextualStrings.removeAll(keepingCapacity: false)
            parakeetPending.removeAll(keepingCapacity: false)
        }

        if requestedEngine == .parakeetEOU120M {
            if processingError == nil {
                do {
                    try await flushParakeetTail()
                    let transcript = try await parakeet?.finish() ?? ""
                    if !transcript
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty {
                        return LocalSpeechWorkerResult(
                            text: transcript,
                            engineUsed: .parakeetEOU120M,
                            usedFallback: false
                        )
                    }
                } catch {
                    processingError = error
                }
            }
            if let fallback = fallbackWhisperEngine() {
                let text = await transcribeWithWhisper(
                    fallback,
                    samples: audio.recognitionSamples(
                        trailingPadding: 1.1
                    )
                )
                if !text.isEmpty {
                    return LocalSpeechWorkerResult(
                        text: text,
                        engineUsed: fallback,
                        usedFallback: true
                    )
                }
            }
            if let text = await transcribeWithAppleFallback(),
               !text.isEmpty {
                return LocalSpeechWorkerResult(
                    text: text,
                    engineUsed: .appleSpeech,
                    usedFallback: true
                )
            }
            if let processingError {
                throw processingError
            }
            return LocalSpeechWorkerResult(
                text: "",
                engineUsed: .parakeetEOU120M,
                usedFallback: false
            )
        }

        guard requestedEngine.isWhisperKit else {
            throw LocalSpeechTranscriptionError.recordingUnavailable(
                "invalid local engine"
            )
        }
        if let processingError {
            throw processingError
        }
        let text = await transcribeWithWhisper(
            requestedEngine,
            // WhisperKit deliberately ignores the last second of an audio
            // window. A full silence tail preserves short utterances and the
            // final phrase after VAD chunking without weakening that guard.
            samples: audio.recognitionSamples(
                trailingPadding: 1.1
            )
        )
        if text.isEmpty,
           let fallback = await transcribeWithAppleFallback(),
           !fallback.isEmpty {
            return LocalSpeechWorkerResult(
                text: fallback,
                engineUsed: .appleSpeech,
                usedFallback: true
            )
        }
        return LocalSpeechWorkerResult(
            text: text,
            engineUsed: requestedEngine,
            usedFallback: false
        )
    }

    func cancel() async {
        activeEngine = nil
        processingError = nil
        partialHandler = nil
        contextualStrings.removeAll(keepingCapacity: false)
        parakeetPending.removeAll(keepingCapacity: false)
        audio.reset(leadingPadding: 0)
        if let parakeet {
            await parakeet.reset()
        }
    }

    func audioMetrics() -> SpeechAudioMetrics {
        audio.metrics
    }

    func unload(_ engine: GeneralDictationEngine) async {
        switch engine {
        case .parakeetEOU120M:
            parakeet = nil
        case .whisperKitBaseEnglish,
             .whisperKitSmallEnglish:
            if let whisperKit = whisperKits.removeValue(
                forKey: engine
            ) {
                await whisperKit.unloadModels()
            }
        case .appleSpeech:
            break
        }
    }

    private func drainParakeetChunks() async throws {
        guard let parakeet else { return }
        while parakeetPending.count >= parakeetFeedFrames {
            let chunk = Array(
                parakeetPending.prefix(parakeetFeedFrames)
            )
            parakeetPending.removeFirst(parakeetFeedFrames)
            guard let buffer = Self.makeBuffer(
                chunk,
                sampleRate:
                    ContinuousSpeechAudioProcessor.outputSampleRate
            ) else { continue }
            _ = try await parakeet.process(audioBuffer: buffer)
        }
    }

    private func flushParakeetTail() async throws {
        guard let parakeet else { return }
        // StreamingEouAsrManager.finish() pads its own final remainder. Feed
        // only captured audio here; adding another 640 ms of silence performs
        // redundant inference and can bias the tail.
        while !parakeetPending.isEmpty {
            let count = min(parakeetFeedFrames, parakeetPending.count)
            let chunk = Array(parakeetPending.prefix(count))
            parakeetPending.removeFirst(count)
            guard let buffer = Self.makeBuffer(
                chunk,
                sampleRate:
                    ContinuousSpeechAudioProcessor.outputSampleRate
            ) else { continue }
            _ = try await parakeet.process(audioBuffer: buffer)
        }
    }

    private func fallbackWhisperEngine() -> GeneralDictationEngine? {
        if whisperKits[.whisperKitSmallEnglish] != nil {
            return .whisperKitSmallEnglish
        }
        if whisperKits[.whisperKitBaseEnglish] != nil {
            return .whisperKitBaseEnglish
        }
        return nil
    }

    private func transcribeWithWhisper(
        _ engine: GeneralDictationEngine,
        samples: [Float]
    ) async -> String {
        guard let whisperKit = whisperKits[engine],
              !samples.isEmpty
        else { return "" }
        let prompt = contextualStrings
            .joined(separator: ", ")
            .prefix(480)
        let promptTokens = prompt.isEmpty
            ? nil
            : whisperKit.tokenizer?.encode(text: String(prompt))
        let options = DecodingOptions(
            language: "en",
            promptTokens: promptTokens,
            concurrentWorkerCount: 2,
            chunkingStrategy: .vad
        )
        let handler = partialHandler
        let batches = await whisperKit.transcribe(
            audioArrays: [samples],
            decodeOptions: options
        ) { progress in
            let text = progress.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !text.isEmpty {
                handler?(text)
            }
            return true
        }
        let results = (batches.first ?? nil) ?? []
        return results
            .map(\.text)
            .joined(separator: " ")
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeWithAppleFallback() async -> String? {
        guard #available(macOS 26.0, *) else { return nil }
        return try? await AppleSpeechBufferTranscriber.transcribe(
            samples: audio.recognitionSamples(
                trailingPadding: 0.24
            ),
            contextualStrings: contextualStrings
        )
    }

    private static func makeBuffer(
        _ samples: [Float],
        sampleRate: Int32
    ) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ),
        let destination = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                destination.update(
                    from: baseAddress,
                    count: source.count
                )
            }
        }
        return buffer
    }

    private static func removeParakeetSourcePackages(
        from modelsRoot: URL
    ) {
        let modelDirectory = modelsRoot.appendingPathComponent(
            "parakeet-eou-streaming/320ms",
            isDirectory: true
        )
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: modelDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where entry.pathExtension == "mlpackage" {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
