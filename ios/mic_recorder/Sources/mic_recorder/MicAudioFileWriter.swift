import AVFoundation
import Foundation

/// Native encoded file output for the mic_recorder plugin: the 16-bit
/// little-endian mono PCM chunks already delivered on the audio stream
/// are also encoded to a file (`AVAudioFile` writer) — AAC-LC or Apple
/// Lossless in an M4A container.
///
/// The writer is fed from the plugin's audio-stream tee (the main
/// thread) and survives pause/resume by design: a pause simply stops the
/// chunks, and the file continues from where it left off on resume.
/// `finish()` closes the file; `abort()` discards and deletes it.
final class MicAudioFileWriter {

    private let lock = NSLock()
    private var file: AVAudioFile?
    private let path: String

    /// The sample rate the file was created for — the plugin's
    /// armed-writer rate guard compares it against the capture rate.
    let sampleRate: Double

    private init(path: String, sampleRate: Double) {
        self.path = path
        self.sampleRate = sampleRate
    }

    /// Creates and opens a writer for `wireName` ("aacLc" or
    /// "appleLossless") at `path`; nil when the file cannot be created
    /// (the caller replies the failure to Dart).
    static func create(
        path: String,
        wireName: String,
        sampleRate: Double,
        bitRate: Int
    ) -> MicAudioFileWriter? {
        let formatID: AudioFormatID

        switch wireName {
        case "aacLc":
            formatID = kAudioFormatMPEG4AAC
        case "appleLossless":
            formatID = kAudioFormatAppleLossless
        default:
            return nil
        }

        var settings: [String: Any] = [
            AVFormatIDKey: formatID,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]

        if wireName == "aacLc" {
            // AAC-LC tops out at 6144 bits per 1024-sample frame per
            // channel — 6 x sampleRate for mono. The Dart default
            // (128 kbps at the default 16 kHz capture rate) exceeds that
            // and Apple's encoder refuses the file rather than clamping,
            // so cap the request here. Anything below the ceiling passes
            // through unchanged; a non-finite rate is left for
            // AVAudioFile to reject.
            if sampleRate.isFinite, sampleRate > 0 {
                let bitRateCeiling = min(sampleRate * 6.0, 9_000_000.0)

                settings[AVEncoderBitRateKey] = min(bitRate, Int(bitRateCeiling))
            } else {
                settings[AVEncoderBitRateKey] = bitRate
            }
        } else {
            settings[AVLinearPCMBitDepthKey] = 16
        }

        // AVAudioFile(forWriting:) overwrites a file that already exists
        // at `path` (documented); the explicit delete simply makes the
        // clobbering obvious and clears stale state up front.
        try? FileManager.default.removeItem(atPath: path)

        guard let file = try? AVAudioFile(
            forWriting: URL(fileURLWithPath: path),
            settings: settings
        ) else {
            return nil
        }

        let writer = MicAudioFileWriter(path: path, sampleRate: sampleRate)

        writer.file = file

        return writer
    }

    /// Feeds one PCM chunk (16-bit little-endian mono at the capture rate).
    func write(_ chunk: Data) {
        let frameCount = chunk.count / 2

        guard frameCount > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        guard let file = file else { return }

        // The file's processing format is float32 deinterleaved mono —
        // convert the int16 chunk into exactly that before writing.
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channel = buffer.floatChannelData?[0] else { return }

        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)

            for index in 0..<frameCount {
                channel[index] = Float(samples[index]) / 32768.0
            }
        }

        do {
            try file.write(from: buffer)
        } catch {
            // A failed write drops this chunk only — capture and the raw
            // stream must keep flowing. The file stays open for the next.
            print("mic_recorder: encoded write failed: \(error.localizedDescription)")
        }
    }

    /// Closes the file (flushing it into a playable M4A).
    func finish() {
        lock.lock()
        defer { lock.unlock() }

        file = nil
    }

    /// Discards the file without finalizing and deletes it.
    func abort() {
        lock.lock()
        defer { lock.unlock() }

        file = nil

        try? FileManager.default.removeItem(atPath: path)
    }
}
