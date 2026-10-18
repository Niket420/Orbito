import Foundation

/// Sends recorded audio to the backend's speech provider (Cactus Whistle) for transcription.
struct SpeechClient {
    let api: APIClient

    func transcribe(samples: [Float]) async throws -> TranscriptionDTO {
        try await api.transcribe(wav: Self.wavData(samples: samples, sampleRate: Int(AudioCapture.sampleRate)))
    }

    /// Encodes Float samples in [-1, 1] as 16-bit PCM mono WAV.
    static func wavData(samples: [Float], sampleRate: Int) -> Data {
        let byteCount = samples.count * 2
        var data = Data(capacity: 44 + byteCount)

        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))              // fmt chunk size
        append(UInt16(1))               // PCM
        append(UInt16(1))               // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))  // byte rate
        append(UInt16(2))               // block align
        append(UInt16(16))              // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}
