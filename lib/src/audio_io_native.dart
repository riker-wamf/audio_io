import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../audio_io.dart' show AudioIoPlaybackStats;
import 'audio_io_stub.dart';
import 'ffi/audio_io_ffi.dart';

class AudioIoNative implements AudioIoImpl {
  AudioIoFFI? _ffi;

  @override
  bool get usePlatformImpl =>
      Platform.isAndroid || Platform.isWindows || Platform.isLinux;

  @override
  Stream<List<double>>? get inputAudioStream => _ffi?.inputAudioStream;

  @override
  StreamSink<List<double>>? get outputAudioStream => _ffi?.outputAudioStream;

  @override
  Stream<Uint8List>? get inputBytesStream => _ffi?.inputBytesStream;

  @override
  StreamSink<Uint8List>? get outputBytesSink => _ffi?.outputBytesSink;

  @override
  Future<void> start({
    int sampleRate = 48000,
    int format = 0,
    // Native backends negotiate [sampleRate] with the device, so the
    // web-only mismatch flag does not apply here.
    bool allowSampleRateMismatch = false,
    // The FFI (Android/Windows/Linux/miniaudio) backend uses a fixed native
    // ring buffer; configurable playback sizing and overflow policy are not
    // wired through the C layer yet (tracked as a follow-up). Accepted for
    // API symmetry and ignored here so callers get consistent behaviour.
    double? playbackBufferSeconds,
    double? maxPlaybackBufferSeconds,
    int overflowPolicy = 0,
  }) async {
    _ffi = AudioIoFFI.instance;
    await _ffi!.start(sampleRate: sampleRate, format: format);
  }

  @override
  Future<void> stop() async {
    await _ffi?.stop();
  }

  @override
  Map<String, dynamic> getFormat() {
    return _ffi?.getFormat() ??
        {
          'input': {
            'type': 'double',
            'channels': 1,
            'sampleRate': 48000.0,
          },
          'output': {
            'type': 'double',
            'channels': 1,
            'sampleRate': 48000.0,
          },
        };
  }

  @override
  Future<void> requestFrameDuration(double duration) async {
    await _ffi?.requestFrameDuration(duration);
  }

  @override
  Future<double> getFrameDuration() async {
    return await _ffi?.getFrameDuration() ?? 0.01;
  }

  @override
  Future<void> flushPlayback() async {
    // The miniaudio C layer exposes no ring-buffer clear primitive yet, so
    // barge-in flush is a no-op on Android/Windows/Linux. Tracked as a
    // follow-up: add an `audio_io_flush_playback` binding. iOS, macOS and web
    // flush immediately.
  }

  @override
  Future<AudioIoPlaybackStats?> playbackStats() async {
    // No playback-queue introspection in the C bindings yet; return null
    // (unsupported) rather than reporting misleading numbers.
    return null;
  }
}

AudioIoImpl createAudioIoImpl() => AudioIoNative();
