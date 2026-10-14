import COpus
import Foundation

enum DualSenseBluetoothSpeakerEncodingError: LocalizedError {
    case encoderCreation(Int32)
    case encoderConfiguration(Int32)
    case encoding(Int32)

    var errorDescription: String? {
        switch self {
        case let .encoderCreation(code):
            return String(localized: "Could not create the speaker encoder (\(code))", bundle: AppResources.localizationBundle)
        case let .encoderConfiguration(code):
            return String(localized: "Could not configure the speaker encoder (\(code))", bundle: AppResources.localizationBundle)
        case let .encoding(code):
            return String(localized: "Could not encode Bluetooth speaker audio (\(code))", bundle: AppResources.localizationBundle)
        }
    }
}

/// Produces the controller's fixed-size, constant-bitrate 10 ms stereo Opus
/// frames away from the main actor.
final class DualSenseBluetoothSpeakerEncoder: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.ianhansel.controldeck.bluetooth-speaker-encode",
        qos: .userInitiated
    )

    func encodeTone(
        frequency: Float,
        duration: TimeInterval,
        volume: Float,
        completion: @escaping (Result<[[UInt8]], Error>) -> Void
    ) {
        queue.async {
            completion(
                Result {
                    try Self.makeToneFrames(
                        frequency: frequency,
                        duration: duration,
                        volume: volume
                    )
                }
            )
        }
    }

    private static func makeToneFrames(
        frequency: Float,
        duration: TimeInterval,
        volume: Float
    ) throws -> [[UInt8]] {
        var opusError: Int32 = OPUS_OK
        guard let encoder = opus_encoder_create(
            Int32(DualSenseBluetoothAudioProtocol.speakerSampleRate),
            Int32(DualSenseBluetoothAudioProtocol.speakerChannelCount),
            OPUS_APPLICATION_AUDIO,
            &opusError
        ) else {
            throw DualSenseBluetoothSpeakerEncodingError.encoderCreation(
                opusError
            )
        }
        defer { opus_encoder_destroy(encoder) }

        let configuration = ps5_opus_configure_dualsense_speaker(encoder)
        guard configuration == OPUS_OK else {
            throw DualSenseBluetoothSpeakerEncodingError.encoderConfiguration(
                configuration
            )
        }

        let frameCount = DualSenseBluetoothAudioProtocol.speakerFrameCount
        let channelCount =
            DualSenseBluetoothAudioProtocol.speakerChannelCount
        let toneSampleCount = max(
            1,
            Int(
                Double(
                    DualSenseBluetoothAudioProtocol.speakerSampleRate
                ) * max(0.01, duration)
            )
        )
        let leadingSilentFrames = 4
        let trailingSilentFrames = 4
        let audibleFrameCount =
            Int(ceil(Double(toneSampleCount) / Double(frameCount)))
        let totalFrameCount =
            leadingSilentFrames + audibleFrameCount + trailingSilentFrames
        let safeVolume = min(max(volume, 0), 0.35)
        let attackSamples = min(480, toneSampleCount / 3)
        let releaseSamples = min(720, toneSampleCount / 3)
        var frames: [[UInt8]] = []
        frames.reserveCapacity(totalFrameCount)

        for packetIndex in 0..<totalFrameCount {
            var pcm = [Float](
                repeating: 0,
                count: frameCount * channelCount
            )
            let audiblePacketIndex = packetIndex - leadingSilentFrames
            if audiblePacketIndex >= 0 &&
                audiblePacketIndex < audibleFrameCount {
                for frame in 0..<frameCount {
                    let sampleIndex = audiblePacketIndex * frameCount + frame
                    guard sampleIndex < toneSampleCount else { break }
                    let attack = attackSamples > 0
                        ? min(1, Float(sampleIndex) / Float(attackSamples))
                        : 1
                    let remaining = toneSampleCount - sampleIndex
                    let release = releaseSamples > 0
                        ? min(1, Float(remaining) / Float(releaseSamples))
                        : 1
                    let phase =
                        Float(sampleIndex) * 2 * .pi * frequency /
                        Float(
                            DualSenseBluetoothAudioProtocol.speakerSampleRate
                        )
                    let sample = sin(phase) * safeVolume * attack * release
                    pcm[frame * channelCount] = sample
                    pcm[frame * channelCount + 1] = sample
                }
            }

            var encoded = [UInt8](
                repeating: 0,
                count: DualSenseBluetoothAudioProtocol.speakerOpusByteCount
            )
            let encodedCapacity = Int32(encoded.count)
            let encodedByteCount = pcm.withUnsafeBufferPointer { pcmBytes in
                encoded.withUnsafeMutableBufferPointer { encodedBytes in
                    opus_encode_float(
                        encoder,
                        pcmBytes.baseAddress!,
                        Int32(frameCount),
                        encodedBytes.baseAddress!,
                        encodedCapacity
                    )
                }
            }
            guard encodedByteCount >= 0 else {
                throw DualSenseBluetoothSpeakerEncodingError.encoding(
                    encodedByteCount
                )
            }
            frames.append(encoded)
        }
        return frames
    }
}
