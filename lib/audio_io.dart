import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/audio_io_stub.dart'
    if (dart.library.io) 'src/audio_io_native.dart'
    if (dart.library.js_interop) 'src/audio_io_web.dart' as impl;

class _Methods {
  static const start = 'start';
  static const stop = 'stop';
  static const requestFrameDuration = 'requestFrameDuration';
  static const getFrameDuration = 'getFrameDuration';
  static const getFormat = 'getFormat';
  static const flushPlayback = 'flushPlayback';
  static const getPlaybackStats = 'getPlaybackStats';
}

class _Channels {
  static const methodChannelName = 'com.wearemobilefirst.audio_io';
  static const audioInput = 'com.wearemobilefirst.audio_io.inputAudio';
  static const audioOutput = 'com.wearemobilefirst.audio_io.outputAudio';
}

class _Constants {
  static const bytesPerSample = 8;
  static const millisecPerSec = 1000;
}

/// Audio format for streaming data.
enum AudioIoFormat {
  /// Float64 samples in [-1.0, 1.0]. Default, backward compatible.
  float64(0),

  /// Signed 16-bit PCM little-endian. For real-time AI APIs.
  pcm16(1);

  const AudioIoFormat(this.value);

  /// Native format identifier.
  final int value;
}

/// Supported sample rates.
enum AudioIoSampleRate {
  /// 16 kHz — speech AI APIs (Gemini Live, Whisper).
  rate16000(16000),

  /// 24 kHz — OpenAI Realtime API.
  rate24000(24000),

  /// 48 kHz — full quality, default.
  rate48000(48000);

  const AudioIoSampleRate(this.hz);

  /// Sample rate in Hz.
  final int hz;
}

enum AudioIoLatency {
  Realtime,
  Balanced,
  Powersave,
}

final Map<AudioIoLatency, double> _presetLatency = {
  AudioIoLatency.Realtime: 1.5 / 1000.0,
  AudioIoLatency.Balanced: 3.0 / 1000.0,
  AudioIoLatency.Powersave: 6.0 / 1000.0,
};

enum AudioIoQuality {
  Low,
  Medium,
  High,
  Highest,
}

/// What the playback queue does when audio arrives faster than it drains —
/// e.g. Gemini Live returning a 40 s response in ~5 s, which is far more than
/// the buffer holds. The previous behaviour silently dropped the entire
/// overflowing chunk; every policy here makes the loss explicit (counted and
/// reportable via [AudioIo.playbackStats]) and lets the caller pick the
/// trade-off that fits their use case.
enum AudioIoOverflowPolicy {
  /// Grow the playback buffer to absorb the burst, up to
  /// [AudioIoConfig.maxPlaybackBufferDuration]. Nothing is dropped until that
  /// hard ceiling is hit. Best for long, self-contained responses (a Gemini
  /// monologue) where you want gapless playback of the whole answer.
  /// This is the default.
  grow(0),

  /// Keep the buffer at its configured size and, when full, discard the
  /// *oldest* queued audio to make room for the newest. Best for strict
  /// real-time where stale audio is worthless and staying current matters
  /// more than completeness.
  dropOldest(1),

  /// Keep the buffer at its configured size and drop *incoming* audio that
  /// does not fit (the historical behaviour — but now counted and signalled
  /// rather than silent).
  dropNewest(2);

  const AudioIoOverflowPolicy(this.value);

  /// Native policy identifier sent over the method channel.
  final int value;
}

/// A snapshot of the playback queue, used to observe latency and detect
/// overflow drops. Returned by [AudioIo.playbackStats].
class AudioIoPlaybackStats {
  /// Frames currently queued and not yet played (the live playback latency,
  /// in frames; divide by the sample rate for seconds).
  final int bufferedFrames;

  /// Current playback-buffer capacity in frames. With
  /// [AudioIoOverflowPolicy.grow] this rises as the buffer grows.
  final int capacityFrames;

  /// Cumulative frames dropped since the last [AudioIo.startWith] because the
  /// queue overflowed. Non-zero means audio was lost — the explicit signal
  /// that replaces the old silent drop. `null` when the platform cannot
  /// report it (e.g. the FFI backend has no drop counter yet).
  final int? droppedFrames;

  const AudioIoPlaybackStats({
    required this.bufferedFrames,
    required this.capacityFrames,
    this.droppedFrames,
  });

  /// Buffered audio expressed as a duration, given [sampleRateHz].
  Duration bufferedDuration(int sampleRateHz) => Duration(
        microseconds:
            sampleRateHz <= 0 ? 0 : bufferedFrames * 1000000 ~/ sampleRateHz,
      );

  factory AudioIoPlaybackStats.fromMap(Map<dynamic, dynamic> map) =>
      AudioIoPlaybackStats(
        bufferedFrames: (map['bufferedFrames'] as num?)?.toInt() ?? 0,
        capacityFrames: (map['capacityFrames'] as num?)?.toInt() ?? 0,
        droppedFrames: (map['droppedFrames'] as num?)?.toInt(),
      );

  @override
  String toString() => 'AudioIoPlaybackStats(buffered: $bufferedFrames, '
      'capacity: $capacityFrames, dropped: $droppedFrames)';
}

/// Configuration for [AudioIo.startWith].
class AudioIoConfig {
  /// Target sample rate.
  final AudioIoSampleRate sampleRate;

  /// Audio data format.
  final AudioIoFormat format;

  /// Latency preset.
  final AudioIoLatency latency;

  /// Frame chunk duration in milliseconds. Null uses the platform default.
  /// When set, input stream emits chunks of approximately this duration.
  /// Valid range: 20–100 ms.
  final int? frameDurationMs;

  /// Web only: accept the browser-controlled AudioContext rate when it
  /// differs from [sampleRate]. On web the browser owns the sample rate
  /// and it cannot be forced; by default [AudioIo.startWith] throws on a
  /// mismatch so callers don't unknowingly stream audio at the wrong rate
  /// (e.g. 48 kHz mislabelled as 16 kHz to a speech API). Set this to
  /// `true` to proceed at the actual rate — read it back via
  /// [AudioIo.getFormat]. Native platforms negotiate [sampleRate] with the
  /// device and ignore this flag.
  final bool allowSampleRateMismatch;

  /// Initial size of the playback (output) ring buffer, expressed as a
  /// duration of audio. This is the latency-vs-underrun knob: a small value
  /// (e.g. 200 ms) keeps real-time conversation responsive, while a large
  /// value protects long responses from underruns on a jittery network.
  ///
  /// `null` uses the platform default of 10 seconds (the prior hardcoded
  /// behaviour). With [AudioIoOverflowPolicy.grow] this is the *starting*
  /// capacity, which may grow up to [maxPlaybackBufferDuration].
  final Duration? playbackBufferDuration;

  /// Hard ceiling the playback buffer may grow to under
  /// [AudioIoOverflowPolicy.grow]. Once reached, further overflow is dropped
  /// and counted (see [AudioIoPlaybackStats.droppedFrames]) rather than
  /// growing memory without bound. Ignored by the other overflow policies,
  /// which never grow.
  ///
  /// `null` derives a sensible ceiling: `max(playbackBufferDuration, 60s)`.
  /// Must be greater than or equal to [playbackBufferDuration].
  final Duration? maxPlaybackBufferDuration;

  /// How the playback queue behaves when audio arrives faster than it drains.
  /// Defaults to [AudioIoOverflowPolicy.grow]. See [AudioIoOverflowPolicy].
  final AudioIoOverflowPolicy playbackOverflow;

  const AudioIoConfig({
    this.sampleRate = AudioIoSampleRate.rate48000,
    this.format = AudioIoFormat.float64,
    this.latency = AudioIoLatency.Balanced,
    this.frameDurationMs,
    this.allowSampleRateMismatch = false,
    this.playbackBufferDuration,
    this.maxPlaybackBufferDuration,
    this.playbackOverflow = AudioIoOverflowPolicy.grow,
  }) : assert(
          frameDurationMs == null ||
              (frameDurationMs >= 20 && frameDurationMs <= 100),
          'frameDurationMs must be between 20 and 100 milliseconds',
        );
  // Note: the playback-duration bounds (>= ~50 ms, and
  // maxPlaybackBufferDuration >= playbackBufferDuration) are not asserted
  // here because Duration comparisons are not const-evaluable and this is a
  // const constructor. The backends are defensive instead: the native floor
  // (minPlaybackSamples) protects tiny values and the growth ceiling is
  // resolved as max(requested-max, initial).

  /// Resolved initial playback-buffer length in seconds, or `null` to let the
  /// native layer apply its 10 s default.
  double? get playbackBufferSeconds => playbackBufferDuration == null
      ? null
      : playbackBufferDuration!.inMicroseconds / 1000000.0;

  /// Resolved growth ceiling in seconds, or `null` for the native default.
  double? get maxPlaybackBufferSeconds => maxPlaybackBufferDuration == null
      ? null
      : maxPlaybackBufferDuration!.inMicroseconds / 1000000.0;
}

class AudioIo {
  MethodChannel _methods = const MethodChannel(_Channels.methodChannelName);
  StreamSubscription<List<double>>? _outputSubscription;
  StreamSubscription? _inputSubscription;
  AudioIoLatency frameSize = AudioIoLatency.Balanced;
  static AudioIo instance = AudioIo();

  final _impl = impl.createAudioIoImpl();

  StreamController<List<double>> _outputController =
      StreamController<List<double>>.broadcast();
  StreamController<List<double>> _inputController =
      StreamController<List<double>>.broadcast();
  final StreamController<Uint8List> _inputBytesController =
      StreamController<Uint8List>.broadcast();
  final StreamController<Uint8List> _outputBytesController =
      StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _outputBytesSubscription;

  AudioIoConfig? _config;

  /// Current configuration. Null before [startWith] is called.
  AudioIoConfig? get currentConfig => _config;

  /// Float64 input stream. Active when format is [AudioIoFormat.float64].
  Stream<List<double>> get input {
    if (_impl.usePlatformImpl) {
      return _impl.inputAudioStream ?? const Stream.empty();
    }
    return _inputController.stream;
  }

  /// Float64 output sink. Active when format is [AudioIoFormat.float64].
  Sink<List<double>> get output {
    if (_impl.usePlatformImpl) {
      return _impl.outputAudioStream ?? StreamController<List<double>>().sink;
    }
    return _outputController.sink;
  }

  /// PCM16 input stream. Active when format is [AudioIoFormat.pcm16].
  /// Each [Uint8List] contains signed 16-bit little-endian PCM samples.
  Stream<Uint8List> get inputBytes {
    if (_impl.usePlatformImpl) {
      return _impl.inputBytesStream ?? const Stream.empty();
    }
    return _inputBytesController.stream;
  }

  /// PCM16 output sink. Active when format is [AudioIoFormat.pcm16].
  /// Write signed 16-bit little-endian PCM bytes.
  Sink<Uint8List> get outputBytes {
    if (_impl.usePlatformImpl) {
      return _impl.outputBytesSink ?? StreamController<Uint8List>().sink;
    }
    return _outputBytesController.sink;
  }

  /// Start with default settings (48 kHz, Float64, Balanced latency).
  ///
  /// Clears any configuration from a prior [startWith] so [currentConfig]
  /// and the native layer fall back to the float64 defaults.
  Future<void> start() async {
    _config = null;
    if (_impl.usePlatformImpl) {
      await _impl.start();
      return;
    }

    _outputSubscription?.cancel();
    _inputSubscription?.cancel();
    _outputBytesSubscription?.cancel();
    _outputSubscription = _outputController.stream.listen((output) {
      final outData = ByteData.view(Float64List.fromList(output).buffer);
      ServicesBinding.instance.defaultBinaryMessenger
          .send(_Channels.audioOutput, outData);
    });
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      _Channels.audioInput,
      (ByteData? message) {
        if (message != null) {
          final audioFrame = message.buffer.asFloat64List(message.offsetInBytes,
              message.lengthInBytes ~/ _Constants.bytesPerSample);
          _inputController.sink.add(audioFrame);
        }
        return null;
      },
    );
    return _methods.invokeMethod(_Methods.start);
  }

  /// Start with explicit configuration.
  Future<void> startWith(AudioIoConfig config) async {
    _config = config;

    if (_impl.usePlatformImpl) {
      if (config.frameDurationMs != null) {
        await _impl.requestFrameDuration(config.frameDurationMs! / 1000.0);
      } else {
        await _impl.requestFrameDuration(_presetLatency[config.latency]!);
      }
      await _impl.start(
        sampleRate: config.sampleRate.hz,
        format: config.format.value,
        allowSampleRateMismatch: config.allowSampleRateMismatch,
        playbackBufferSeconds: config.playbackBufferSeconds,
        maxPlaybackBufferSeconds: config.maxPlaybackBufferSeconds,
        overflowPolicy: config.playbackOverflow.value,
      );
      return;
    }

    // iOS/macOS method channel path
    final frameDuration = config.frameDurationMs != null
        ? config.frameDurationMs! / 1000.0
        : _presetLatency[config.latency]!;
    await _methods.invokeMethod(_Methods.requestFrameDuration, frameDuration);

    _outputSubscription?.cancel();
    _inputSubscription?.cancel();
    _outputBytesSubscription?.cancel();

    if (config.format == AudioIoFormat.pcm16) {
      _outputBytesSubscription =
          _outputBytesController.stream.listen((bytes) {
        final data = ByteData.sublistView(bytes);
        ServicesBinding.instance.defaultBinaryMessenger
            .send(_Channels.audioOutput, data);
      });
      ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
        _Channels.audioInput,
        (ByteData? message) {
          if (message != null) {
            final bytes = message.buffer.asUint8List(
              message.offsetInBytes,
              message.lengthInBytes,
            );
            _inputBytesController.sink.add(bytes);
          }
          return null;
        },
      );
    } else {
      _outputSubscription = _outputController.stream.listen((output) {
        final outData = ByteData.view(Float64List.fromList(output).buffer);
        ServicesBinding.instance.defaultBinaryMessenger
            .send(_Channels.audioOutput, outData);
      });
      ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
        _Channels.audioInput,
        (ByteData? message) {
          if (message != null) {
            final audioFrame = message.buffer.asFloat64List(
                message.offsetInBytes,
                message.lengthInBytes ~/ _Constants.bytesPerSample);
            _inputController.sink.add(audioFrame);
          }
          return null;
        },
      );
    }

    return _methods.invokeMethod(_Methods.start, {
      'sampleRate': config.sampleRate.hz,
      'format': config.format.value,
      // null lets the native side keep its 10 s / derived defaults.
      'playbackBufferSeconds': config.playbackBufferSeconds,
      'maxPlaybackBufferSeconds': config.maxPlaybackBufferSeconds,
      'overflowPolicy': config.playbackOverflow.value,
    });
  }

  Future<void> stop() async {
    if (_impl.usePlatformImpl) {
      await _impl.stop();
      return;
    }
    ServicesBinding.instance.defaultBinaryMessenger
        .setMessageHandler(_Channels.audioInput, null);
    await _outputSubscription?.cancel();
    await _inputSubscription?.cancel();
    await _outputBytesSubscription?.cancel();
    await _methods.invokeMethod(_Methods.stop);
  }

  /// Immediately drop all queued, not-yet-played output audio.
  ///
  /// This is the barge-in / interrupt primitive: when Gemini Live (or any
  /// streaming source) reports an `interrupted` event, call this so the
  /// already-queued — now stale — audio stops playing at once instead of
  /// talking over the user. Capture/playback stay running; only the pending
  /// output queue is cleared. Feeding new audio afterwards resumes playback
  /// normally.
  Future<void> flushPlayback() async {
    if (_impl.usePlatformImpl) {
      await _impl.flushPlayback();
      return;
    }
    await _methods.invokeMethod(_Methods.flushPlayback);
  }

  /// Snapshot of the playback queue — buffered/queued frames, current
  /// capacity, and the cumulative overflow-drop counter. Use it to monitor
  /// playback latency and to detect when audio is being dropped (the explicit
  /// signal that replaces the old silent tail-drop). Returns `null` if the
  /// platform cannot report stats.
  Future<AudioIoPlaybackStats?> playbackStats() async {
    if (_impl.usePlatformImpl) {
      return _impl.playbackStats();
    }
    final value = await _methods.invokeMethod(_Methods.getPlaybackStats);
    if (value is Map) {
      return AudioIoPlaybackStats.fromMap(value);
    }
    return null;
  }

  Future<Map<String, dynamic>?> getFormat() async {
    if (_impl.usePlatformImpl) {
      return _impl.getFormat();
    }
    final value = await _methods.invokeMethod(_Methods.getFormat);
    if (value != null && value is Map<String, dynamic>) {
      return value;
    }
    return null;
  }

  Future<void> requestLatency(AudioIoLatency option) async {
    if (_impl.usePlatformImpl) {
      await _impl.requestFrameDuration(_presetLatency[option]!);
      return;
    }
    return _methods.invokeMethod(
        _Methods.requestFrameDuration, _presetLatency[option]);
  }

  Future<double> currentLatency() async {
    if (_impl.usePlatformImpl) {
      final latency = await _impl.getFrameDuration();
      return latency * _Constants.millisecPerSec;
    }
    return _methods.invokeMethod(_Methods.getFrameDuration).then((latency) {
      return (latency as double) * _Constants.millisecPerSec;
    });
  }

  void dispose() {
    if (_impl.usePlatformImpl) {
      _impl.stop();
      return;
    }
    ServicesBinding.instance.defaultBinaryMessenger
        .setMessageHandler(_Channels.audioInput, null);
    unawaited(_outputSubscription?.cancel());
    unawaited(_inputSubscription?.cancel());
    unawaited(_outputBytesSubscription?.cancel());
    _outputController.sink.close();
    _outputController.close();
    _inputController.sink.close();
    _inputController.close();
    _inputBytesController.close();
    _outputBytesController.close();
  }
}
