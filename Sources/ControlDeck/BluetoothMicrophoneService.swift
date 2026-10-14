import AVFoundation
import COpus
import Foundation
import OSLog

@MainActor
final class BluetoothMicrophoneService: ObservableObject {
    @Published private(set) var isPublished = false
    @Published private(set) var isCapturing = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var peakInputLevel: Float = 0
    @Published private(set) var receivedPacketCount = 0
    @Published private(set) var decodedFrameCount = 0
    @Published private(set) var concealedFrameCount = 0
    @Published private(set) var timelineGapCount = 0
    @Published private(set) var duplicatePacketCount = 0
    @Published private(set) var lastResult = String(localized: "Wireless microphone is offline", bundle: AppResources.localizationBundle)

    private let publisher = ProcessTapMicrophoneService()
    private let pipeline = BluetoothOpusPipeline()
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var engineConfigurationObserver: NSObjectProtocol?
    private var captureGeneration: UInt64?
    private var captureStartedAt: ContinuousClock.Instant?
    private var loggedFirstDecodedFrame = false
    private var decodedPCMHandler: (@Sendable ([Float], Int) -> Void)?
    private let logger = Logger(
        subsystem: "com.ianhansel.controldeck",
        category: "bluetooth-microphone"
    )

    /// The public aggregate fed by the private Bluetooth decoder. Consumers
    /// can record it directly without making it the system-default microphone.
    var speechInputDeviceID: AudioObjectID? {
        guard isPublished,
              publisher.aggregateDeviceID != kAudioObjectUnknown
        else { return nil }
        return publisher.aggregateDeviceID
    }

    @discardableResult
    func prepare() -> Bool {
        guard #available(macOS 14.2, *) else {
            lastResult = String(localized: "Bluetooth microphone requires macOS 14.2 or later", bundle: AppResources.localizationBundle)
            return false
        }

        if let engine, !engine.isRunning {
            guard recoverAudioBridge(engine) else { return false }
        } else if engine == nil {
            guard startSilentAudioBridge() else { return false }
        }
        guard publisher.publish() else {
            lastResult = publisher.lastResult
            stopAudioBridge()
            return false
        }

        isPublished = true
        lastResult = publisher.lastResult
        return true
    }

    @discardableResult
    func startCapture() -> Bool {
        guard prepare() else { return false }
        let session = pipeline.reset()
        guard session.decoderResult == OPUS_OK else {
            captureGeneration = nil
            isCapturing = false
            inputLevel = 0
            lastResult =
                String(localized: "Could not create Opus decoder (\(session.decoderResult))", bundle: AppResources.localizationBundle)
            return false
        }
        captureGeneration = session.generation
        receivedPacketCount = 0
        decodedFrameCount = 0
        concealedFrameCount = 0
        timelineGapCount = 0
        duplicatePacketCount = 0
        inputLevel = 0
        peakInputLevel = 0
        loggedFirstDecodedFrame = false
        captureStartedAt = ContinuousClock.now
        isCapturing = true
        lastResult = String(localized: "Waiting for DualSense Bluetooth audio", bundle: AppResources.localizationBundle)
        logger.notice("Bluetooth microphone diagnostic capture started")

        let generation = session.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in
            guard let self,
                  self.isCapturing,
                  self.captureGeneration == generation,
                  self.receivedPacketCount == 0
            else {
                return
            }
            self.lastResult =
                String(localized: "No microphone packets yet — check the Bluetooth connection", bundle: AppResources.localizationBundle)
        }
        return true
    }

    func stopCapture() {
        if isCapturing {
            let elapsed = captureStartedAt.map {
                ContinuousClock.now - $0
            }
            let elapsedSeconds = elapsed.map {
                Double($0.components.seconds) +
                    Double($0.components.attoseconds) / 1e18
            } ?? 0
            let pcmSeconds = Double(decodedFrameCount) /
                Double(DualSenseBluetoothAudioProtocol.microphoneSampleRate)
            logger.notice(
                "Bluetooth microphone stopped; packets=\(self.receivedPacketCount, privacy: .public) decodedFrames=\(self.decodedFrameCount, privacy: .public) concealedFrames=\(self.concealedFrameCount, privacy: .public) timelineGaps=\(self.timelineGapCount, privacy: .public) duplicates=\(self.duplicatePacketCount, privacy: .public) pcmSeconds=\(pcmSeconds, privacy: .public) elapsedSeconds=\(elapsedSeconds, privacy: .public) peak=\(self.peakInputLevel, privacy: .public)"
            )
        }
        decodedPCMHandler = nil
        captureGeneration = nil
        captureStartedAt = nil
        isCapturing = false
        pipeline.clear()
        inputLevel = 0
        lastResult = isPublished
            ? String(localized: "\(ProcessTapMicrophoneService.deviceName) is ready", bundle: AppResources.localizationBundle)
            : String(localized: "Wireless microphone is offline", bundle: AppResources.localizationBundle)
    }

    func teardown() {
        stopCapture()
        publisher.unpublish()
        isPublished = false
        stopAudioBridge()
    }

    func runAudioBridgeSelfTest() {
        guard prepare() else { return }
        pipeline.playTestTone(duration: 15)
        lastResult = String(localized: "Playing a private test signal into DualSense Microphone", bundle: AppResources.localizationBundle)
    }

    /// Adds a direct consumer for each decoded mono 48 kHz frame. This avoids
    /// routing in-app transcription back through the virtual Core Audio device,
    /// while leaving that published device available to external consumers.
    func setDecodedPCMHandler(
        _ handler: (@Sendable ([Float], Int) -> Void)?
    ) {
        decodedPCMHandler = handler
    }

    func ingest(_ packet: DualSenseBluetoothMicrophonePacket) {
        guard isCapturing,
              packet.opusPayload.count ==
                DualSenseBluetoothAudioProtocol.microphoneOpusByteCount
        else {
            return
        }

        guard let generation = captureGeneration else { return }
        let pcmHandler = decodedPCMHandler
        pipeline.enqueue(
            packet,
            generation: generation,
            pcmHandler: pcmHandler
        ) {
            [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.isCapturing,
                      self.captureGeneration == result.generation
                else {
                    return
                }

                self.receivedPacketCount += result.receivedPackets
                self.decodedFrameCount += result.decodedFrames
                self.concealedFrameCount += result.concealedFrames
                self.timelineGapCount += result.timelineGaps
                self.duplicatePacketCount += result.duplicatePackets
                self.inputLevel = result.level
                self.peakInputLevel = max(
                    self.peakInputLevel,
                    result.level
                )

                if let decodeError = result.decodeError {
                    self.lastResult =
                        String(localized: "Opus decode failed (\(decodeError))", bundle: AppResources.localizationBundle)
                } else if result.decodedFrames > 0 {
                    self.lastResult =
                        String(localized: "Receiving DualSense Bluetooth microphone", bundle: AppResources.localizationBundle)
                    if !self.loggedFirstDecodedFrame {
                        self.loggedFirstDecodedFrame = true
                        self.logger.notice(
                            "Decoded first Bluetooth microphone frame; level=\(result.level, privacy: .public)"
                        )
                    }
                }
            }
        }
    }

    private func startSilentAudioBridge() -> Bool {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(
                DualSenseBluetoothAudioProtocol.microphoneSampleRate
            ),
            channels: 2
        ) else {
            lastResult = String(localized: "Could not create the wireless microphone format", bundle: AppResources.localizationBundle)
            return false
        }

        let engine = AVAudioEngine()
        let ring = pipeline.ring
        let sourceNode = AVAudioSourceNode(format: format) {
            _, _, frameCount, audioBufferList -> OSStatus in
            ring.render(
                frameCount: Int(frameCount),
                into: audioBufferList
            )
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            lastResult = String(localized: "Could not start the audio bridge: \(error.localizedDescription)", bundle: AppResources.localizationBundle)
            return false
        }

        self.sourceNode = sourceNode
        self.engine = engine
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let engine = self.engine else {
                    return
                }
                _ = self.recoverAudioBridge(engine)
            }
        }
        return true
    }

    @discardableResult
    private func recoverAudioBridge(_ expectedEngine: AVAudioEngine) -> Bool {
        guard engine === expectedEngine else { return engine?.isRunning == true }
        if expectedEngine.isRunning {
            return true
        }
        do {
            try expectedEngine.start()
            return true
        } catch {
            // A hardware route change can invalidate the old graph. Recreate
            // only that graph; retain the decoder/ring during active capture.
            stopAudioBridge(clearPipeline: !isCapturing)
            guard startSilentAudioBridge() else {
                lastResult =
                    String(localized: "Wireless microphone audio engine stopped: ", bundle: AppResources.localizationBundle) +
                    error.localizedDescription
                return false
            }
            return true
        }
    }

    private func stopAudioBridge(clearPipeline: Bool = true) {
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(
                engineConfigurationObserver
            )
            self.engineConfigurationObserver = nil
        }
        engine?.stop()
        if clearPipeline {
            pipeline.clear()
        }
        engine = nil
        sourceNode = nil
    }
}

private struct BluetoothPipelineSession {
    let generation: UInt64
    let decoderResult: Int32
}

private struct BluetoothDecodeResult {
    let generation: UInt64
    let receivedPackets: Int
    let decodedFrames: Int
    let concealedFrames: Int
    let timelineGaps: Int
    let duplicatePackets: Int
    let level: Float
    let decodeError: Int32?
}

private final class BluetoothOpusPipeline: @unchecked Sendable {
    private struct DecodedFrame {
        let samples: [Float]
        let frameCount: Int
        let error: Int32?
    }

    let ring = MicrophonePCMRingBuffer()

    private let queue = DispatchQueue(
        label: "com.ianhansel.controldeck.bluetooth-microphone-decode",
        qos: .userInteractive
    )
    private var decoder: OpaquePointer?
    private var generation: UInt64 = 0
    private var pendingPacketCount = 0
    private var pendingDecodedFrameCount = 0
    private var pendingConcealedFrameCount = 0
    private var pendingTimelineGapCount = 0
    private var pendingDuplicatePacketCount = 0
    private var pendingLevel: Float = 0
    private var pendingDecodeError: Int32?
    private var totalPacketCount = 0
    private var packetTimeline = DualSenseBluetoothPacketTimeline()
    private var lastMetricsEmissionNanoseconds: UInt64 = 0
    private let metricsEmissionIntervalNanoseconds: UInt64 = 100_000_000

    deinit {
        if let decoder {
            opus_decoder_destroy(decoder)
        }
    }

    func reset() -> BluetoothPipelineSession {
        queue.sync {
            generation &+= 1
            if let decoder {
                opus_decoder_destroy(decoder)
                self.decoder = nil
            }
            ring.reset()
            resetPendingMetrics()
            var error: Int32 = 0
            decoder = opus_decoder_create(
                Int32(DualSenseBluetoothAudioProtocol.microphoneSampleRate),
                1,
                &error
            )
            return BluetoothPipelineSession(
                generation: generation,
                decoderResult: error
            )
        }
    }

    func clear() {
        queue.sync {
            generation &+= 1
            if let decoder {
                opus_decoder_destroy(decoder)
                self.decoder = nil
            }
            resetPendingMetrics()
            ring.reset()
        }
    }

    func playTestTone(duration: TimeInterval) {
        ring.playTestTone(duration: duration)
    }

    func enqueue(
        _ packet: DualSenseBluetoothMicrophonePacket,
        generation requestedGeneration: UInt64,
        pcmHandler: (@Sendable ([Float], Int) -> Void)?,
        completion: @escaping (BluetoothDecodeResult) -> Void
    ) {
        queue.async { [weak self] in
            guard let self,
                  requestedGeneration == self.generation,
                  let decoder = self.decoder
            else {
                return
            }
            let timing = self.packetTimeline.observe(packet)
            self.pendingPacketCount += 1
            self.totalPacketCount += 1
            self.pendingTimelineGapCount += timing.timelineGaps
            var level: Float = 0
            if timing.isDuplicate {
                self.pendingDuplicatePacketCount += 1
            } else {
                for _ in 0..<timing.concealCount {
                    let concealed = self.decode(
                        payload: nil,
                        decoder: decoder
                    )
                    if concealed.frameCount > 0 {
                        self.publish(
                            concealed,
                            pcmHandler: pcmHandler
                        )
                        self.pendingDecodedFrameCount +=
                            concealed.frameCount
                        self.pendingConcealedFrameCount +=
                            concealed.frameCount
                        level = max(
                            level,
                            self.level(of: concealed)
                        )
                    } else if let error = concealed.error {
                        self.pendingDecodeError = error
                        break
                    }
                }

                let decoded = self.decode(
                    payload: packet.opusPayload,
                    decoder: decoder
                )
                if decoded.frameCount > 0 {
                    self.publish(decoded, pcmHandler: pcmHandler)
                    self.pendingDecodedFrameCount += decoded.frameCount
                    level = max(level, self.level(of: decoded))
                } else if let error = decoded.error {
                    self.pendingDecodeError = error
                }
            }

            guard requestedGeneration == self.generation else { return }
            self.pendingLevel = max(self.pendingLevel, level)

            let now = DispatchTime.now().uptimeNanoseconds
            let isFirstPacket = self.totalPacketCount == 1
            let intervalElapsed =
                now &- self.lastMetricsEmissionNanoseconds >=
                self.metricsEmissionIntervalNanoseconds
            guard isFirstPacket || intervalElapsed else { return }

            completion(
                BluetoothDecodeResult(
                    generation: requestedGeneration,
                    receivedPackets: self.pendingPacketCount,
                    decodedFrames: self.pendingDecodedFrameCount,
                    concealedFrames:
                        self.pendingConcealedFrameCount,
                    timelineGaps: self.pendingTimelineGapCount,
                    duplicatePackets:
                        self.pendingDuplicatePacketCount,
                    level: self.pendingLevel,
                    decodeError: self.pendingDecodeError
                )
            )
            self.pendingPacketCount = 0
            self.pendingDecodedFrameCount = 0
            self.pendingConcealedFrameCount = 0
            self.pendingTimelineGapCount = 0
            self.pendingDuplicatePacketCount = 0
            self.pendingLevel = 0
            self.pendingDecodeError = nil
            self.lastMetricsEmissionNanoseconds = now
        }
    }

    private func decode(
        payload: Data?,
        decoder: OpaquePointer
    ) -> DecodedFrame {
        var mono = [Float](
            repeating: 0,
            count: DualSenseBluetoothAudioProtocol.microphoneFrameCount
        )
        let decodedFrames: Int32
        if let payload {
            decodedFrames = payload.withUnsafeBytes { encodedBytes in
                mono.withUnsafeMutableBufferPointer { pcm in
                    opus_decode_float(
                        decoder,
                        encodedBytes.bindMemory(
                            to: UInt8.self
                        ).baseAddress,
                        Int32(payload.count),
                        pcm.baseAddress!,
                        Int32(
                            DualSenseBluetoothAudioProtocol
                                .microphoneFrameCount
                        ),
                        0
                    )
                }
            }
        } else {
            decodedFrames = mono.withUnsafeMutableBufferPointer { pcm in
                opus_decode_float(
                    decoder,
                    nil,
                    0,
                    pcm.baseAddress!,
                    Int32(
                        DualSenseBluetoothAudioProtocol
                            .microphoneFrameCount
                    ),
                    0
                )
            }
        }
        guard decodedFrames > 0 else {
            return DecodedFrame(
                samples: [],
                frameCount: 0,
                error: decodedFrames < 0 ? decodedFrames : nil
            )
        }
        return DecodedFrame(
            samples: mono,
            frameCount: Int(decodedFrames),
            error: nil
        )
    }

    private func publish(
        _ frame: DecodedFrame,
        pcmHandler: (@Sendable ([Float], Int) -> Void)?
    ) {
        ring.write(frame.samples, count: frame.frameCount)
        pcmHandler?(frame.samples, frame.frameCount)
    }

    private func level(of frame: DecodedFrame) -> Float {
        guard frame.frameCount > 0 else { return 0 }
        var energy: Float = 0
        for sample in frame.samples.prefix(frame.frameCount) {
            energy += sample * sample
        }
        let rms = sqrt(energy / Float(frame.frameCount))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(1, max(0, (decibels + 60) / 60))
    }

    private func resetPendingMetrics() {
        pendingPacketCount = 0
        pendingDecodedFrameCount = 0
        pendingConcealedFrameCount = 0
        pendingTimelineGapCount = 0
        pendingDuplicatePacketCount = 0
        pendingLevel = 0
        pendingDecodeError = nil
        totalPacketCount = 0
        packetTimeline.reset()
        lastMetricsEmissionNanoseconds = 0
    }
}

private final class MicrophonePCMRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [Float](repeating: 0, count: 96_000)
    private var readIndex = 0
    private var writeIndex = 0
    private var availableFrames = 0
    private var isPrimed = false
    private var testToneFramesRemaining = 0
    private var testTonePhase: Float = 0
    private let primeFrames = 2_400 // 50 ms of Bluetooth jitter tolerance.

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        readIndex = 0
        writeIndex = 0
        availableFrames = 0
        isPrimed = false
        testToneFramesRemaining = 0
        testTonePhase = 0
    }

    func playTestTone(duration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        testToneFramesRemaining = max(
            0,
            Int(
                duration * Double(
                    DualSenseBluetoothAudioProtocol.microphoneSampleRate
                )
            )
        )
        testTonePhase = 0
    }

    func write(_ samples: [Float], count: Int) {
        lock.lock()
        defer { lock.unlock() }
        let safeCount = min(max(0, count), samples.count)
        for index in 0..<safeCount {
            let sample = samples[index]
            if availableFrames == storage.count {
                readIndex = (readIndex + 1) % storage.count
                availableFrames -= 1
            }
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % storage.count
            availableFrames += 1
        }

        // Recover from an interrupted render callback without carrying seconds
        // of stale speech into the next Codex capture window.
        if availableFrames > storage.count * 3 / 4 {
            let target = primeFrames * 2
            let framesToDrop = availableFrames - target
            readIndex = (readIndex + framesToDrop) % storage.count
            availableFrames = target
        }
    }

    func render(
        frameCount: Int,
        into audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        // AVAudioSourceNode invokes this on a real-time thread. Never wait for
        // the decoder/reset writer: a contested callback emits silence and
        // catches up on the next render quantum.
        guard lock.try() else {
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                memset(data, 0, Int(buffer.mDataByteSize))
            }
            return
        }
        defer { lock.unlock() }

        if !isPrimed, availableFrames >= primeFrames {
            isPrimed = true
        }

        for frame in 0..<frameCount {
            let sample: Float
            if testToneFramesRemaining > 0 {
                sample = sin(testTonePhase) * 0.16
                testTonePhase += 2 * .pi * 523.25 /
                    Float(
                        DualSenseBluetoothAudioProtocol.microphoneSampleRate
                    )
                testToneFramesRemaining -= 1
            } else if isPrimed, availableFrames > 0 {
                sample = storage[readIndex]
                readIndex = (readIndex + 1) % storage.count
                availableFrames -= 1
            } else {
                sample = 0
            }
            if isPrimed, availableFrames == 0 {
                isPrimed = false
            }

            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let destination = data.assumingMemoryBound(to: Float.self)
                for channel in 0..<channels {
                    destination[frame * channels + channel] = sample
                }
            }
        }
    }
}
