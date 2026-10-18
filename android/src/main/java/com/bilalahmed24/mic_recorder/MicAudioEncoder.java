package com.bilalahmed24.mic_recorder;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.os.Build;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;

/**
 * Native encoded file output: 16-bit little-endian mono PCM in, an encoded
 * file out (AAC-LC in M4A, Opus in Ogg, FLAC, AMR-NB, AMR-WB).
 *
 * <p>The encoder is fed from the plugin's audio-stream sink (the main
 * thread) and survives pause/resume cycles by design: a pause simply stops
 * the chunks (Android tears capture down), and the presentation
 * timestamps — derived from the total frames fed, not wall time — resume
 * exactly where they left off. {@link #finish()} drains, finalizes and
 * closes; {@link #abort()} releases and deletes.
 *
 * <p>Wire names (the Dart enum's): {@code aacLc}, {@code opus},
 * {@code flac}, {@code amrNb}, {@code amrWb}. {@code appleLossless} is
 * iOS-only and is rejected here.
 */
final class MicAudioEncoder {

    private static final String TAG = "MicRecorder";

    /** Codec/muxer handshake timeout per call, microseconds. */
    private static final long TIMEOUT_US = 10_000L;

    /** Drain iterations before giving up waiting for end-of-stream. */
    private static final int EOS_DRAIN_LIMIT = 100;

    /** AMR-NB file magic (a raw AMR stream starts with it). */
    private static final byte[] AMR_NB_MAGIC = "#!AMR\n".getBytes();

    /** AMR-WB file magic. */
    private static final byte[] AMR_WB_MAGIC = "#!AMR-WB\n".getBytes();

    /** FLAC stream magic (the metadata block that follows comes as csd-0). */
    private static final byte[] FLAC_MAGIC = "fLaC".getBytes();

    private final Object lock = new Object();

    private final String path;
    private final int sampleRate;
    private final int bitRate;

    private MediaCodec codec;
    private MediaMuxer muxer;
    private OutputStream rawOutput;

    private boolean started;
    private boolean muxerTrackAdded;
    private int muxerTrackIndex;
    private boolean wroteAnySample;
    private boolean flacHeaderWritten;
    private boolean isFlac;

    private long framesFed;

    private MicAudioEncoder(String path, int sampleRate, int bitRate) {
        this.path = path;
        this.sampleRate = sampleRate;
        this.bitRate = bitRate;
    }

    /** The capture rate this encoder was built for. */
    int sampleRate() {
        return sampleRate;
    }

    /**
     * Creates and starts an encoder session for [wireName] writing to
     * [path]; throws [IOException] when the codec or container cannot be
     * opened (the caller replies the failure to Dart).
     */
    static MicAudioEncoder create(String path, String wireName, int sampleRate, int bitRate)
            throws IOException {
        final MicAudioEncoder encoder = new MicAudioEncoder(path, sampleRate, bitRate);

        synchronized (encoder.lock) {
            encoder.open(wireName);
        }

        return encoder;
    }

    // ------------------------------------------------------------------
    // Session setup
    // ------------------------------------------------------------------

    private void open(String wireName) throws IOException {
        final String mime;
        final boolean useMuxer;
        final int muxerFormat;

        switch (wireName) {
            case "aacLc":
                mime = MediaFormat.MIMETYPE_AUDIO_AAC;
                useMuxer = true;
                muxerFormat = MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4;
                break;
            case "opus":
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    throw new IOException(
                            "Opus in Ogg requires Android 10 (API 29)+");
                }
                mime = MediaFormat.MIMETYPE_AUDIO_OPUS;
                useMuxer = true;
                muxerFormat = MediaMuxer.OutputFormat.MUXER_OUTPUT_OGG;
                break;
            case "flac":
                mime = MediaFormat.MIMETYPE_AUDIO_FLAC;
                useMuxer = false;
                muxerFormat = 0;
                break;
            case "amrNb":
                if (sampleRate != 8000) {
                    throw new IOException("AMR-NB requires 8000 Hz capture");
                }
                mime = MediaFormat.MIMETYPE_AUDIO_AMR_NB;
                useMuxer = false;
                muxerFormat = 0;
                break;
            case "amrWb":
                if (sampleRate != 16000) {
                    throw new IOException("AMR-WB requires 16000 Hz capture");
                }
                mime = MediaFormat.MIMETYPE_AUDIO_AMR_WB;
                useMuxer = false;
                muxerFormat = 0;
                break;
            default:
                throw new IOException("Unsupported encoder: " + wireName);
        }

        try {
            codec = MediaCodec.createEncoderByType(mime);

            isFlac = MediaFormat.MIMETYPE_AUDIO_FLAC.equals(mime);

            final MediaFormat format = new MediaFormat();

            format.setString(MediaFormat.KEY_MIME, mime);
            format.setInteger(MediaFormat.KEY_SAMPLE_RATE, sampleRate);
            format.setInteger(MediaFormat.KEY_CHANNEL_COUNT, 1);

            if (isFlac) {
                // Lossless: no bit rate; the (optional) compression level
                // key only exists from API 31 on.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    format.setInteger(
                            MediaFormat.KEY_FLAC_COMPRESSION_LEVEL, 5);
                }
            } else {
                // AAC-LC needs no profile key (it is the codec default).
                format.setInteger(MediaFormat.KEY_BIT_RATE, bitRate);
            }

            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            codec.start();

            if (useMuxer) {
                muxer = new MediaMuxer(path, muxerFormat);
            } else {
                rawOutput = new FileOutputStream(path);

                if (mime.equals(MediaFormat.MIMETYPE_AUDIO_AMR_NB)) {
                    rawOutput.write(AMR_NB_MAGIC);
                } else if (mime.equals(MediaFormat.MIMETYPE_AUDIO_AMR_WB)) {
                    rawOutput.write(AMR_WB_MAGIC);
                }
                // FLAC's "fLaC" magic is written when csd-0 arrives, keeping
                // the stream header + STREAMINFO adjacent as the format needs.
            }

            started = true;
        } catch (IOException | IllegalStateException e) {
            releaseQuietly();

            throw new IOException("Encoder open failed: " + e.getMessage(), e);
        }
    }

    // ------------------------------------------------------------------
    // Recording
    // ------------------------------------------------------------------

    /** Feeds one PCM chunk (called on the main thread by the stream sink). */
    void write(byte[] pcm) {
        if (pcm.length == 0) return;

        synchronized (lock) {
            if (!started || codec == null) return;

            try {
                int offset = 0;

                while (offset < pcm.length) {
                    final int inputIndex =
                            codec.dequeueInputBuffer(TIMEOUT_US);

                    if (inputIndex < 0) {
                        drainOutputs(false);

                        continue;
                    }

                    final ByteBuffer input = codec.getInputBuffer(inputIndex);

                    if (input == null) {
                        drainOutputs(false);

                        return;
                    }

                    input.clear();

                    final int size = Math.min(
                            input.capacity(), pcm.length - offset);

                    input.put(pcm, offset, size);

                    // Presentation time of THIS buffer = the instant of its
                    // first sample; the paused gap between chunks therefore
                    // lands in the timeline exactly where it belongs.
                    final long presentationUs =
                            framesFed * 1_000_000L / sampleRate;

                    framesFed += size / 2L;

                    codec.queueInputBuffer(
                            inputIndex, 0, size, presentationUs, 0);

                    offset += size;

                    drainOutputs(false);
                }
            } catch (IOException | IllegalStateException e) {
                Log.e(TAG, "Encoder write failed: " + e.getMessage());

                abortLocked();
            }
        }
    }

    /**
     * Finalizes the file: drains the codec to end-of-stream, stops the
     * muxer (or flushes the raw stream) and closes everything.
     *
     * @return whether a usable file was produced (a session that never
     *         encoded a sample is deleted instead).
     */
    boolean finish() {
        synchronized (lock) {
            if (!started) return false;

            try {
                queueEndOfStream();

                drainOutputs(true);
            } catch (IOException | IllegalStateException e) {
                Log.e(TAG, "Encoder finish drain failed: " + e.getMessage());
            }

            releaseQuietly();

            started = false;

            if (!wroteAnySample) {
                // An empty container is not a playable file — discard it.
                deleteFile();

                return false;
            }

            return true;
        }
    }

    /** Releases without finalizing and deletes the partial file. */
    void abort() {
        synchronized (lock) {
            abortLocked();
        }
    }

    private void queueEndOfStream() throws IOException {
        // A zero-byte buffer carrying only the EOS flag terminates input.
        final int inputIndex = codec.dequeueInputBuffer(TIMEOUT_US);

        if (inputIndex < 0) {
            // The codec is too backed up to take the marker; the drain
            // loop below still flushes whatever was queued.
            return;
        }

        codec.queueInputBuffer(
                inputIndex, 0, 0, framesFed * 1_000_000L / sampleRate,
                MediaCodec.BUFFER_FLAG_END_OF_STREAM);
    }

    // ------------------------------------------------------------------
    // Output plumbing
    // ------------------------------------------------------------------

    private void drainOutputs(boolean waitForEos) throws IOException {
        final MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();

        int iterations = 0;

        while (iterations++ < (waitForEos ? EOS_DRAIN_LIMIT : 8)) {
            final int outputIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US);

            if (outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (!waitForEos) return;

                continue;
            }

            if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                ensureMuxerTrack();

                continue;
            }

            if (outputIndex < 0) continue;

            final ByteBuffer output = codec.getOutputBuffer(outputIndex);

            if (output != null && info.size > 0) {
                final boolean isConfig =
                        (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;

                if (isConfig) {
                    writeConfigSample(output, info);
                } else {
                    ensureMuxerTrack();

                    writeEncodedSample(output, info);
                }
            }

            codec.releaseOutputBuffer(outputIndex, false);

            if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                return;
            }
        }
    }

    private void ensureMuxerTrack() throws IOException {
        if (muxer == null || muxerTrackAdded) return;

        // After the codec config surfaces, getOutputFormat() carries the
        // csd-0 the container needs — add the track and roll the muxer.
        muxerTrackIndex = muxer.addTrack(codec.getOutputFormat());

        muxer.start();

        muxerTrackAdded = true;
    }

    private void writeConfigSample(ByteBuffer buffer, MediaCodec.BufferInfo info)
            throws IOException {
        // FLAC: csd-0 IS file content — the STREAMINFO metadata block,
        // which must sit immediately after the stream magic. AMR's csd is
        // a mode list, not file content (nothing to write).
        if (isFlac && rawOutput != null) {
            if (!flacHeaderWritten) {
                rawOutput.write(FLAC_MAGIC);

                flacHeaderWritten = true;
            }

            final byte[] header = new byte[info.size];

            buffer.position(info.offset);
            buffer.get(header);

            rawOutput.write(header);
        }
    }

    private void writeEncodedSample(ByteBuffer buffer, MediaCodec.BufferInfo info)
            throws IOException {
        if (muxer != null) {
            buffer.position(info.offset);
            buffer.limit(info.offset + info.size);

            muxer.writeSampleData(muxerTrackIndex, buffer, info);
        } else if (rawOutput != null) {
            final byte[] chunk = new byte[info.size];

            buffer.position(info.offset);
            buffer.get(chunk);

            rawOutput.write(chunk);
        }

        wroteAnySample = true;
    }

    // ------------------------------------------------------------------
    // Teardown
    // ------------------------------------------------------------------

    private void abortLocked() {
        releaseQuietly();

        started = false;

        deleteFile();
    }

    private void releaseQuietly() {
        try {
            if (muxer != null) {
                // A muxer that never wrote samples cannot be stopped —
                // stopping one anyway throws; release is the safe path.
                if (muxerTrackAdded && wroteAnySample) {
                    muxer.stop();
                }

                muxer.release();
            }
        } catch (Exception e) {
            Log.w(TAG, "Muxer release failed: " + e.getMessage());
        } finally {
            muxer = null;
        }

        try {
            if (rawOutput != null) {
                rawOutput.flush();

                rawOutput.close();
            }
        } catch (Exception e) {
            Log.w(TAG, "Raw output close failed: " + e.getMessage());
        } finally {
            rawOutput = null;
        }

        try {
            if (codec != null) {
                codec.stop();
            }
        } catch (Exception e) {
            // The codec may already be in an error state — expected.
        } finally {
            try {
                if (codec != null) codec.release();
            } catch (Exception e) {
                // Release must never throw out of teardown.
            } finally {
                codec = null;
            }
        }
    }

    private void deleteFile() {
        try {
            final File file = new File(path);

            if (file.exists() && !file.delete()) {
                Log.w(TAG, "Failed to delete encoder output: " + path);
            }
        } catch (Exception e) {
            Log.w(TAG, "Failed to delete encoder output: " + e.getMessage());
        }
    }
}
