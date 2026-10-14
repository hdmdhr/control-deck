import ApplicationServices
import AppKit
import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import OSLog
import Speech

struct AppleSpeechTranscriptionResult: Equatable {
    enum InsertionMethod: Equatable {
        case accessibility
        case pasteboard
    }

    let text: String
    let insertionMethod: InsertionMethod
}

enum AppleSpeechTranscriptionError: LocalizedError, Equatable {
    case requiresMacOS26
    case accessibilityRequired
    case microphonePermissionDenied
    case speechPermissionDenied
    case noTextField
    case unsupportedLocale
    case modelUnavailable
    case microphoneUnavailable
    case recordingUnavailable
    case noSpeechDetected
    case targetUnavailable

    var errorDescription: String? {
        switch self {
        case .requiresMacOS26:
            String(localized: "Apple SpeechTranscriber requires macOS 26 or later", bundle: AppResources.localizationBundle)
        case .accessibilityRequired:
            String(localized: "Accessibility is required to insert dictated text", bundle: AppResources.localizationBundle)
        case .microphonePermissionDenied:
            String(localized: "Enable ControlDeck in Privacy & Security → Microphone", bundle: AppResources.localizationBundle)
        case .speechPermissionDenied:
            String(localized: "Speech Recognition permission is required for Apple transcription", bundle: AppResources.localizationBundle)
        case .noTextField:
            String(localized: "Focus the app where dictated text should be inserted", bundle: AppResources.localizationBundle)
        case .unsupportedLocale:
            String(localized: "Apple SpeechTranscriber does not support the current language", bundle: AppResources.localizationBundle)
        case .modelUnavailable:
            String(localized: "The Apple speech model could not be prepared", bundle: AppResources.localizationBundle)
        case .microphoneUnavailable:
            String(localized: "The selected microphone is unavailable", bundle: AppResources.localizationBundle)
        case .recordingUnavailable:
            String(localized: "Apple transcription could not start", bundle: AppResources.localizationBundle)
        case .noSpeechDetected:
            String(localized: "No speech was detected", bundle: AppResources.localizationBundle)
        case .targetUnavailable:
            String(localized: "The original text field is no longer available", bundle: AppResources.localizationBundle)
        }
    }
}

/// Runs Apple's local SpeechTranscriber without moving focus away from the
/// user's current text field. The transcript is returned to that exact field;
/// the system-default input device is never changed.
@MainActor
final class AppleSpeechTranscriptionService {
    private var storage: AnyObject?
    var onPartialTranscript: ((String) -> Void)?
    var onInputLevel: ((Float) -> Void)?

    var isActive: Bool {
        guard #available(macOS 26.0, *),
              let session = storage as? AppleSpeechTranscriptionSession
        else { return false }
        return session.isActive
    }

    var isReady: Bool {
        guard #available(macOS 26.0, *),
              let session = storage as? AppleSpeechTranscriptionSession
        else { return false }
        return session.isReady
    }

    @discardableResult
    func begin(
        inputDeviceID: AudioObjectID?,
        externalPCMSampleRate: Double? = nil,
        target: SpeechTextInsertionTarget? = nil,
        contextualStrings: [String] = [],
        completion: @escaping (
            Result<Void, AppleSpeechTranscriptionError>
        ) -> Void
    ) -> Bool {
        guard #available(macOS 26.0, *) else {
            completion(.failure(.requiresMacOS26))
            return false
        }
        guard storage == nil else {
            completion(.failure(.recordingUnavailable))
            return false
        }
        let session = AppleSpeechTranscriptionSession(
            externalPCMSampleRate: externalPCMSampleRate,
            contextualStrings: contextualStrings,
            onPartialTranscript: { [weak self] text in
                self?.onPartialTranscript?(text)
            },
            onInputLevel: { [weak self] level in
                Task { @MainActor in
                    self?.onInputLevel?(level)
                }
            }
        )
        storage = session
        return session.begin(
            inputDeviceID: inputDeviceID,
            target: target
        ) {
            [weak self] result in
            if case .failure = result {
                self?.storage = nil
            }
            completion(result)
        }
    }

    /// Returns a thread-safe sink for decoded controller PCM when this session
    /// was started with `externalPCMSampleRate`. The Bluetooth decoder can call
    /// it directly from its serial queue without involving the main thread.
    var externalPCMHandler: (@Sendable ([Float], Int) -> Void)? {
        guard #available(macOS 26.0, *),
              let session = storage as? AppleSpeechTranscriptionSession
        else { return nil }
        return session.externalPCMHandler
    }

    @discardableResult
    func finish(
        recordingStopped: @escaping () -> Void,
        completion: @escaping (
            Result<AppleSpeechTranscriptionResult, AppleSpeechTranscriptionError>
        ) -> Void
    ) -> Bool {
        guard #available(macOS 26.0, *),
              let session = storage as? AppleSpeechTranscriptionSession
        else {
            completion(.failure(.recordingUnavailable))
            return false
        }
        return session.finish(
            recordingStopped: recordingStopped
        ) { [weak self] result in
            self?.storage = nil
            completion(result)
        }
    }

    @discardableResult
    func cancel() -> Bool {
        guard #available(macOS 26.0, *),
              let session = storage as? AppleSpeechTranscriptionSession
        else {
            storage = nil
            return true
        }
        let cancelled = session.cancel()
        storage = nil
        return cancelled
    }
}

@available(macOS 26.0, *)
@MainActor
private final class AppleSpeechTranscriptionSession {
    private enum Phase {
        case idle
        case preparing
        case recording
        case finishing
    }

    private var phase: Phase = .idle
    private var generation = 0
    private var target: SpeechTextInsertionTarget?
    private var engine: AVAudioEngine?
    private let externalPCMInput: AppleSpeechPCMInput?
    private let logger = Logger(
        subsystem: "com.ianhansel.controldeck",
        category: "apple-speech"
    )

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var transcript = ""
    private let contextualStrings: [String]
    private let onPartialTranscript: (String) -> Void
    private let onInputLevel: @Sendable (Float) -> Void
    private var pendingFinish: (
        recordingStopped: () -> Void,
        completion: (
            Result<
                AppleSpeechTranscriptionResult,
                AppleSpeechTranscriptionError
            >
        ) -> Void
    )?

    var isActive: Bool { phase != .idle }
    var isReady: Bool { phase == .recording }

    init(
        externalPCMSampleRate: Double?,
        contextualStrings: [String],
        onPartialTranscript: @escaping (String) -> Void,
        onInputLevel: @escaping @Sendable (Float) -> Void
    ) {
        self.contextualStrings = contextualStrings
        self.onPartialTranscript = onPartialTranscript
        self.onInputLevel = onInputLevel
        if let externalPCMSampleRate {
            externalPCMInput = AppleSpeechPCMInput(
                sampleRate: externalPCMSampleRate,
                onInputLevel: onInputLevel
            )
        } else {
            externalPCMInput = nil
        }
    }

    var externalPCMHandler: (@Sendable ([Float], Int) -> Void)? {
        guard let externalPCMInput else { return nil }
        return { samples, count in
            externalPCMInput.append(samples, count: count)
        }
    }

    @discardableResult
    func begin(
        inputDeviceID: AudioObjectID?,
        target: SpeechTextInsertionTarget?,
        completion: @escaping (
            Result<Void, AppleSpeechTranscriptionError>
        ) -> Void
    ) -> Bool {
        guard phase == .idle else {
            completion(.failure(.recordingUnavailable))
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

        generation += 1
        let session = generation
        phase = .preparing
        self.target = target
        transcript = ""
        pendingFinish = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard await self.requestMicrophonePermission() else {
                    throw AppleSpeechTranscriptionError
                        .microphonePermissionDenied
                }
                guard await self.requestSpeechPermission() else {
                    throw AppleSpeechTranscriptionError
                        .speechPermissionDenied
                }
                try await self.prepareSession(
                    generation: session,
                    inputDeviceID: inputDeviceID
                )
                guard self.generation == session,
                      self.phase == .preparing
                else { return }
                self.phase = .recording
                self.logger.notice(
                    "SpeechTranscriber recording ready; source=\(self.externalPCMInput == nil ? "audio-device" : "direct-bluetooth-pcm", privacy: .public)"
                )
                completion(.success(()))
                if let pending = self.pendingFinish {
                    self.pendingFinish = nil
                    // A held button can be released while the first-use model
                    // or permission is preparing. Give the freshly-started
                    // input tap one short window to drain buffered controller
                    // audio before honoring that queued stop.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                        guard self.generation == session,
                              self.phase == .recording
                        else { return }
                        _ = self.finish(
                            recordingStopped: pending.recordingStopped,
                            completion: pending.completion
                        )
                    }
                }
            } catch let error as AppleSpeechTranscriptionError {
                guard self.generation == session else { return }
                self.reset()
                completion(.failure(error))
            } catch {
                guard self.generation == session else { return }
                self.reset()
                completion(.failure(.recordingUnavailable))
            }
        }
        return true
    }

    @discardableResult
    func finish(
        recordingStopped: @escaping () -> Void,
        completion: @escaping (
            Result<AppleSpeechTranscriptionResult, AppleSpeechTranscriptionError>
        ) -> Void
    ) -> Bool {
        switch phase {
        case .preparing:
            pendingFinish = (recordingStopped, completion)
            return true
        case .recording:
            phase = .finishing
            let session = generation
            stopAudioInput()
            recordingStopped()
            externalPCMInput?.stopAccepting()
            inputContinuation?.finish()
            inputContinuation = nil

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.analyzer?
                        .finalizeAndFinishThroughEndOfInput()
                    await self.resultsTask?.value
                    guard self.generation == session,
                          self.phase == .finishing
                    else { return }
                    let text = self.transcript
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let metrics = self.externalPCMInput?.snapshot()
                    self.logger.notice(
                        "SpeechTranscriber finished; transcriptCharacters=\(text.count, privacy: .public) pcmFrames=\(metrics?.receivedFrames ?? 0, privacy: .public) convertedFrames=\(metrics?.convertedFrames ?? 0, privacy: .public) peak=\(metrics?.peak ?? 0, privacy: .public) droppedFrames=\(metrics?.droppedFrames ?? 0, privacy: .public)"
                    )
                    guard !text.isEmpty else {
                        self.reset()
                        completion(.failure(.noSpeechDetected))
                        return
                    }
                    guard let method = self.target?.insert(text) else {
                        self.reset()
                        completion(.failure(.targetUnavailable))
                        return
                    }
                    let result = AppleSpeechTranscriptionResult(
                        text: text,
                        insertionMethod: method
                    )
                    self.reset()
                    completion(.success(result))
                } catch {
                    guard self.generation == session else { return }
                    self.reset()
                    completion(.failure(.recordingUnavailable))
                }
            }
            return true
        case .finishing:
            return false
        case .idle:
            completion(.failure(.recordingUnavailable))
            return false
        }
    }

    @discardableResult
    func cancel() -> Bool {
        guard phase != .idle else { return true }
        generation += 1
        stopAudioInput()
        externalPCMInput?.stopAccepting()
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
        reset()
        return true
    }

    @available(macOS 26.0, *)
    private func prepareSession(
        generation session: Int,
        inputDeviceID: AudioObjectID?
    ) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechTranscriptionError.modelUnavailable
        }
        let requestedLocale = Locale.autoupdatingCurrent
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else {
            throw AppleSpeechTranscriptionError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .transcription
        )
        if let installation = try await AssetInventory
            .assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        guard generation == session, phase == .preparing else { return }

        let modules: [any SpeechModule] = [transcriber]
        guard let analyzerFormat = await SpeechAnalyzer
            .bestAvailableAudioFormat(compatibleWith: modules)
        else {
            throw AppleSpeechTranscriptionError.modelUnavailable
        }
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(
                contextualStrings.prefix(32)
            )
            try await analyzer.setContext(context)
        }

        let (inputStream, continuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self
        )
        self.analyzer = analyzer
        inputContinuation = continuation
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.generation == session else { return }
                    self.appendTranscript(String(result.text.characters))
                    self.onPartialTranscript(self.transcript)
                }
            } catch {
                // The finish path reports a useful error if no final result
                // was produced; cancellation also terminates this sequence.
            }
        }

        try await analyzer.start(inputSequence: inputStream)
        guard generation == session, phase == .preparing else { return }
        if let externalPCMInput {
            try externalPCMInput.configure(
                analyzerFormat: analyzerFormat,
                continuation: continuation
            )
            logger.notice(
                "Direct controller PCM attached to SpeechTranscriber; sourceRate=\(externalPCMInput.sampleRate, privacy: .public) analyzerFormat=\(analyzerFormat.description, privacy: .public)"
            )
        } else {
            try startAudioInput(
                deviceID: inputDeviceID,
                analyzerFormat: analyzerFormat,
                continuation: continuation
            )
            logger.notice(
                "Audio device attached to SpeechTranscriber; deviceID=\(inputDeviceID ?? kAudioObjectUnknown, privacy: .public) analyzerFormat=\(analyzerFormat.description, privacy: .public)"
            )
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission {
                    continuation.resume(returning: $0)
                }
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func requestSpeechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization {
                    continuation.resume(returning: $0 == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    @available(macOS 26.0, *)
    private func startAudioInput(
        deviceID: AudioObjectID?,
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if var selectedDevice = deviceID {
            guard let audioUnit = input.audioUnit else {
                throw AppleSpeechTranscriptionError.microphoneUnavailable
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
                throw AppleSpeechTranscriptionError.microphoneUnavailable
            }
        }

        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0,
              sourceFormat.channelCount > 0,
              let converter = AVAudioConverter(
                  from: sourceFormat,
                  to: analyzerFormat
              )
        else {
            throw AppleSpeechTranscriptionError.microphoneUnavailable
        }

        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: sourceFormat
        ) { buffer, _ in
            guard let converted = Self.convert(
                buffer,
                using: converter,
                to: analyzerFormat
            ) else { return }
            let level = Self.level(of: converted)
            Task { @MainActor [weak self] in
                self?.onInputLevel(level)
            }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AppleSpeechTranscriptionError.recordingUnavailable
        }
        self.engine = engine
    }

    private func stopAudioInput() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(
            max(1, ceil(Double(input.frameLength) * ratio) + 64)
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
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
              output.frameLength > 0
        else { return nil }
        return output
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0],
              buffer.frameLength > 0
        else { return 0 }
        var energy: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            energy += channel[index] * channel[index]
        }
        let rms = sqrt(energy / Float(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(1, max(0, (decibels + 60) / 60))
    }

    private func appendTranscript(_ segment: String) {
        let clean = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if transcript.isEmpty {
            transcript = clean
        } else if transcript.last?.isWhitespace == true ||
                    clean.first?.isPunctuation == true {
            transcript += clean
        } else {
            transcript += " " + clean
        }
    }

    private func reset() {
        stopAudioInput()
        externalPCMInput?.stopAccepting()
        phase = .idle
        target = nil
        transcript = ""
        pendingFinish = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        inputContinuation = nil
    }
}

@available(macOS 26.0, *)
private struct AppleSpeechPCMMetrics {
    let receivedFrames: Int
    let convertedFrames: Int
    let droppedFrames: Int
    let peak: Float
}

/// Thread-safe adapter from the DualSense decoder's mono Float32 frames to the
/// format selected by SpeechAnalyzer. Audio received while Apple's model is
/// preparing is retained so a user can start speaking immediately.
@available(macOS 26.0, *)
private final class AppleSpeechPCMInput: @unchecked Sendable {
    let sampleRate: Double

    private let lock = NSLock()
    private let onInputLevel: @Sendable (Float) -> Void
    private let sourceFormat: AVAudioFormat
    private let maximumBufferedFrames: Int
    private var pendingChunks: [[Float]] = []
    private var pendingFrameCount = 0
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var accepting = true
    private var receivedFrames = 0
    private var convertedFrames = 0
    private var droppedFrames = 0
    private var peak: Float = 0

    init(
        sampleRate: Double,
        onInputLevel: @escaping @Sendable (Float) -> Void
    ) {
        self.sampleRate = sampleRate
        self.onInputLevel = onInputLevel
        sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        maximumBufferedFrames = Int(sampleRate * 60)
    }

    func append(_ samples: [Float], count: Int) {
        let safeCount = min(max(0, count), samples.count)
        guard safeCount > 0 else { return }
        let chunk = Array(samples.prefix(safeCount))

        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return }

        receivedFrames += safeCount
        var maximum: Float = 0
        var energy: Float = 0
        for sample in chunk {
            maximum = max(maximum, abs(sample))
            energy += sample * sample
        }
        peak = max(peak, maximum)
        let rms = sqrt(energy / Float(chunk.count))
        let decibels = 20 * log10(max(rms, 0.000_01))
        onInputLevel(min(1, max(0, (decibels + 60) / 60)))

        if converter != nil {
            convertAndYieldLocked(chunk)
            return
        }

        pendingChunks.append(chunk)
        pendingFrameCount += safeCount
        while pendingFrameCount > maximumBufferedFrames,
              !pendingChunks.isEmpty {
            let removed = pendingChunks.removeFirst()
            pendingFrameCount -= removed.count
            droppedFrames += removed.count
        }
    }

    func configure(
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        guard let converter = AVAudioConverter(
            from: sourceFormat,
            to: analyzerFormat
        ) else {
            throw AppleSpeechTranscriptionError.microphoneUnavailable
        }

        lock.lock()
        defer { lock.unlock() }
        guard accepting else {
            throw AppleSpeechTranscriptionError.recordingUnavailable
        }
        self.converter = converter
        self.analyzerFormat = analyzerFormat
        self.continuation = continuation
        for chunk in pendingChunks {
            convertAndYieldLocked(chunk)
        }
        pendingChunks.removeAll(keepingCapacity: false)
        pendingFrameCount = 0
    }

    func stopAccepting() {
        lock.lock()
        accepting = false
        pendingChunks.removeAll(keepingCapacity: false)
        pendingFrameCount = 0
        converter = nil
        analyzerFormat = nil
        continuation = nil
        lock.unlock()
    }

    func snapshot() -> AppleSpeechPCMMetrics {
        lock.lock()
        defer { lock.unlock() }
        return AppleSpeechPCMMetrics(
            receivedFrames: receivedFrames,
            convertedFrames: convertedFrames,
            droppedFrames: droppedFrames,
            peak: peak
        )
    }

    private func convertAndYieldLocked(_ samples: [Float]) {
        guard let converter,
              let analyzerFormat,
              let continuation,
              let input = AVAudioPCMBuffer(
                  pcmFormat: sourceFormat,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let destination = input.floatChannelData?[0]
        else {
            droppedFrames += samples.count
            return
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            destination.update(from: baseAddress, count: samples.count)
        }

        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(
            max(1, ceil(Double(samples.count) * ratio) + 64)
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: analyzerFormat,
            frameCapacity: capacity
        ) else {
            droppedFrames += samples.count
            return
        }

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
              output.frameLength > 0
        else {
            droppedFrames += samples.count
            return
        }
        convertedFrames += Int(output.frameLength)
        continuation.yield(AnalyzerInput(buffer: output))
    }
}
