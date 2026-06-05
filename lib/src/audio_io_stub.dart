import 'dart:async';
import 'dart:typed_data';

import '../audio_io.dart' show AudioIoPlaybackStats;

abstract class AudioIoImpl {
  bool get usePlatformImpl;
  Stream<List<double>>? get inputAudioStream;
  StreamSink<List<double>>? get outputAudioStream;
  Stream<Uint8List>? get inputBytesStream;
  StreamSink<Uint8List>? get outputBytesSink;

  /// Starts capture/playback. [allowSampleRateMismatch] only affects the
  /// web implementation, where the browser controls the AudioContext rate
  /// and the requested rate cannot be guaranteed (see [AudioIoImpl]
  /// docs / web impl). Native backends honour [sampleRate] via the device
  /// and ignore this flag.
  ///
  /// [playbackBufferSeconds], [maxPlaybackBufferSeconds] and [overflowPolicy]
  /// configure the output queue (initial size, growth ceiling, and what
  /// happens on overflow). `null` durations select the backend default.
  Future<void> start({
    int sampleRate = 48000,
    int format = 0,
    bool allowSampleRateMismatch = false,
    double? playbackBufferSeconds,
    double? maxPlaybackBufferSeconds,
    int overflowPolicy = 0,
  });
  Future<void> stop();
  Map<String, dynamic> getFormat();
  Future<void> requestFrameDuration(double duration);
  Future<double> getFrameDuration();

  /// Drops all queued, not-yet-played output audio (barge-in / interrupt).
  Future<void> flushPlayback();

  /// Snapshot of the playback queue, or `null` if unsupported.
  Future<AudioIoPlaybackStats?> playbackStats();
}

AudioIoImpl createAudioIoImpl() => throw UnsupportedError(
    'Cannot create audio implementation on this platform');
