import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import '../audio_io.dart' show AudioIoOverflowPolicy, AudioIoPlaybackStats;
import 'audio_io_stub.dart';

@JS('window')
external JSObject get window;

@JS('AudioContext')
@staticInterop
class AudioContext {
  external factory AudioContext();
}

extension AudioContextExt on AudioContext {
  external double get sampleRate;
  external String get state;
  external JSPromise resume();
  external JSPromise close();
  external ScriptProcessorNode createScriptProcessor(
    int bufferSize,
    int inputChannels,
    int outputChannels,
  );
  external AudioDestinationNode get destination;
  external MediaStreamAudioSourceNode createMediaStreamSource(
    web.MediaStream stream,
  );
}

@JS()
@staticInterop
class AudioDestinationNode {}

@JS()
@staticInterop
class MediaStreamAudioSourceNode {}

extension MediaStreamAudioSourceNodeExt on MediaStreamAudioSourceNode {
  external void connect(ScriptProcessorNode node);
}

@JS()
@staticInterop
class ScriptProcessorNode {}

extension ScriptProcessorNodeExt on ScriptProcessorNode {
  external set onaudioprocess(JSFunction? handler);
  external void connect(AudioDestinationNode destination);
  external void disconnect();
}

@JS()
@staticInterop
class AudioProcessingEvent {}

extension AudioProcessingEventExt on AudioProcessingEvent {
  external AudioBuffer get inputBuffer;
  external AudioBuffer get outputBuffer;
}

@JS()
@staticInterop
class AudioBuffer {}

extension AudioBufferExt on AudioBuffer {
  external JSFloat32Array getChannelData(int channel);
  external int get length;
}

class AudioIoWeb implements AudioIoImpl {
  static const _pcm16FormatValue = 1;
  // Default ScriptProcessor buffer (~42.67ms at 48kHz) when no explicit frame
  // duration is requested, or when a request is too small for web to honour.
  static const _defaultBufferSize = 2048;
  // ScriptProcessorNode only accepts power-of-two buffer sizes in this range.
  static const _minBufferSize = 256;
  static const _maxBufferSize = 16384;
  // Requests below this (e.g. the native 1.5–6ms latency presets) cannot be
  // delivered reliably by the main-thread ScriptProcessor, so they fall back to
  // the default buffer. The public `frameDurationMs` knob starts at 20ms.
  static const _minHonouredFrameDuration = 0.02;
  // Playback queue defaults, in seconds, matching the native backends.
  static const _defaultPlaybackSeconds = 10.0;
  static const _defaultMaxPlaybackSeconds = 60.0;

  AudioContext? _audioContext;
  ScriptProcessorNode? _scriptProcessor;
  StreamController<List<double>>? _inputController;
  StreamController<List<double>>? _outputController;
  StreamController<Uint8List>? _inputBytesController;
  StreamController<Uint8List>? _outputBytesController;
  final Queue<double> _outputBuffer = Queue<double>();
  bool _isRunning = false;
  int _format = 0;
  int _requestedSampleRate = 48000;
  // Frame duration requested via requestFrameDuration(); applied at start(),
  // where the AudioContext sample rate is known. Null until requested.
  double? _requestedFrameDuration;
  // Actual ScriptProcessor buffer size chosen for the running pipeline, so
  // getFrameDuration() can report the duration the caller really gets.
  int _activeBufferSize = _defaultBufferSize;

  // Playback queue sizing/policy, resolved at start() once the AudioContext
  // sample rate is known. The web "queue" is a software FIFO (_outputBuffer)
  // feeding the ScriptProcessor; these bound it instead of letting it grow
  // without limit and surface drops via playbackStats().
  double? _requestedPlaybackSeconds;
  double? _requestedMaxPlaybackSeconds;
  AudioIoOverflowPolicy _overflowPolicy = AudioIoOverflowPolicy.grow;
  int _playbackTargetSamples = 1 << 30;
  int _playbackMaxSamples = 1 << 30;
  int _droppedFrames = 0;

  @override
  bool get usePlatformImpl => true;

  @override
  Stream<List<double>>? get inputAudioStream => _inputController?.stream;

  @override
  StreamSink<List<double>>? get outputAudioStream => _outputController?.sink;

  @override
  Stream<Uint8List>? get inputBytesStream => _inputBytesController?.stream;

  @override
  StreamSink<Uint8List>? get outputBytesSink => _outputBytesController?.sink;

  @override
  Future<void> start({
    int sampleRate = 48000,
    int format = 0,
    bool allowSampleRateMismatch = false,
    double? playbackBufferSeconds,
    double? maxPlaybackBufferSeconds,
    int overflowPolicy = 0,
  }) async {
    if (_isRunning) {
      // A same-config restart is a no-op; a reconfigure (different rate or
      // format) while running would silently keep the first config, so
      // surface it instead of swallowing it.
      if (sampleRate != _requestedSampleRate || format != _format) {
        throw StateError(
          'audio_io is already started; call stop() before reconfiguring '
          '(requested sampleRate=$sampleRate, format=$format; '
          'current sampleRate=$_requestedSampleRate, format=$_format)',
        );
      }
      return;
    }
    _format = format;
    _requestedSampleRate = sampleRate;
    _requestedPlaybackSeconds = playbackBufferSeconds;
    _requestedMaxPlaybackSeconds = maxPlaybackBufferSeconds;
    _overflowPolicy =
        AudioIoOverflowPolicy.values[overflowPolicy.clamp(0, 2)];
    _droppedFrames = 0;

    try {
      _audioContext = AudioContext();
      final actualRate = _audioContext!.sampleRate.toInt();
      if (sampleRate != actualRate) {
        // The browser controls the AudioContext rate; it cannot be forced.
        // Proceeding silently would emit `actualRate` audio mislabelled as
        // `sampleRate` (e.g. 48 kHz sent to a 16 kHz Gemini Live endpoint),
        // producing aliased / wrong-speed audio with no surfaced error.
        // Fail loudly unless the caller has explicitly opted in.
        if (!allowSampleRateMismatch) {
          await _audioContext!.close().toDart;
          _audioContext = null;
          throw StateError(
            'Web AudioContext runs at ${actualRate}Hz but ${sampleRate}Hz '
            'was requested. The browser controls this rate and it cannot be '
            'changed. Either request ${actualRate}Hz (see getFormat()), '
            'resample on your side, or pass '
            'allowSampleRateMismatch: true to accept ${actualRate}Hz audio.',
          );
        }
        debugPrint(
          'Warning: Web AudioContext runs at ${actualRate}Hz, '
          'requested ${sampleRate}Hz. Audio will use ${actualRate}Hz.',
        );
      }

      if (_audioContext!.state == 'suspended') {
        await _audioContext!.resume().toDart;
      }

      _activeBufferSize = _resolveBufferSize(_audioContext!.sampleRate);
      _resolvePlaybackBounds(_audioContext!.sampleRate);
      _scriptProcessor = _audioContext!.createScriptProcessor(
        _activeBufferSize,
        1,
        1,
      );

      _inputController = StreamController<List<double>>.broadcast();
      _outputController = StreamController<List<double>>();
      _inputBytesController = StreamController<Uint8List>.broadcast();
      _outputBytesController = StreamController<Uint8List>();

      if (_format == _pcm16FormatValue) {
        _outputBytesController!.stream.listen((bytes) {
          _enqueueOutput(_pcm16LeToFloat32(bytes));
        });
      } else {
        _outputController!.stream.listen((data) {
          _enqueueOutput(data);
        });
      }

      _scriptProcessor!.onaudioprocess = ((JSAny event) {
        final audioEvent = event as AudioProcessingEvent;
        final inputBuffer = audioEvent.inputBuffer;
        final outputBuffer = audioEvent.outputBuffer;

        final bufferLength = inputBuffer.length;

        final inputData = inputBuffer.getChannelData(0);
        final inputList = <double>[];
        for (int i = 0; i < bufferLength; i++) {
          final value = inputData.getProperty(i.toJS) as JSNumber?;
          inputList.add(value?.toDartDouble ?? 0.0);
        }

        if (_format == _pcm16FormatValue) {
          _inputBytesController?.add(_float32ListToPcm16Le(inputList));
        } else {
          _inputController?.add(inputList);
        }

        final outputData = outputBuffer.getChannelData(0);
        for (int i = 0; i < bufferLength; i++) {
          final value = _outputBuffer.isNotEmpty
              ? _outputBuffer.removeFirst()
              : 0.0;
          outputData.setProperty(i.toJS, value.toJS);
        }
      }).toJS;

      _scriptProcessor!.connect(_audioContext!.destination);

      // _getUserMedia() throws on permission/device failure. Letting it
      // propagate means a denied mic surfaces as a startup error rather than a
      // "successful" start with permanently silent input.
      final mediaStream = await _getUserMedia();
      final source = _audioContext!.createMediaStreamSource(mediaStream);
      source.connect(_scriptProcessor!);

      _isRunning = true;
    } catch (e) {
      // Any failure between AudioContext creation and a fully-running pipeline
      // (sample-rate mismatch, mic acquisition, etc.) must leave no half-open
      // context/processor/controllers behind and keep _isRunning false.
      await _teardownAfterFailedStart();
      throw Exception('Failed to start audio: $e');
    }
  }

  Future<web.MediaStream> _getUserMedia() async {
    try {
      final constraints = web.MediaStreamConstraints(audio: true.toJS);

      final stream = await web.window.navigator.mediaDevices
          .getUserMedia(constraints)
          .toDart;
      return stream;
    } catch (e) {
      debugPrint('Failed to get user media: $e');
      throw StateError(
        'Microphone access failed (permission denied or no input device): $e',
      );
    }
  }

  Future<void> _teardownAfterFailedStart() async {
    _isRunning = false;

    _scriptProcessor?.disconnect();
    _scriptProcessor = null;

    await _audioContext?.close().toDart;
    _audioContext = null;

    await _inputController?.close();
    await _outputController?.close();
    await _inputBytesController?.close();
    await _outputBytesController?.close();
    _inputController = null;
    _outputController = null;
    _inputBytesController = null;
    _outputBytesController = null;
    _outputBuffer.clear();
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;

    _isRunning = false;

    _scriptProcessor?.disconnect();
    _scriptProcessor = null;

    await _audioContext?.close().toDart;
    _audioContext = null;

    await _inputController?.close();
    await _outputController?.close();
    await _inputBytesController?.close();
    await _outputBytesController?.close();
    _inputController = null;
    _outputController = null;
    _inputBytesController = null;
    _outputBytesController = null;
    _outputBuffer.clear();
  }

  @override
  Map<String, dynamic> getFormat() {
    final sampleRate = _audioContext?.sampleRate ?? 48000.0;
    final type = _format == _pcm16FormatValue ? 'pcm16' : 'double';

    return {
      'input': {'type': type, 'channels': 1, 'sampleRate': sampleRate},
      'output': {'type': type, 'channels': 1, 'sampleRate': sampleRate},
    };
  }

  @override
  Future<void> requestFrameDuration(double duration) async {
    // The Web Audio ScriptProcessorNode buffer size is fixed at creation, so
    // the request is recorded here and applied in start() once the
    // AudioContext sample rate is known. Read back via getFrameDuration().
    _requestedFrameDuration = duration;
  }

  @override
  Future<double> getFrameDuration() async {
    final sampleRate = _audioContext?.sampleRate ?? 48000.0;
    return _activeBufferSize / sampleRate;
  }

  @override
  Future<void> flushPlayback() async {
    // Barge-in: drop everything still queued for playback. Capture/playback
    // stay running; the next output frames simply start a fresh queue.
    _outputBuffer.clear();
  }

  @override
  Future<AudioIoPlaybackStats?> playbackStats() async {
    return AudioIoPlaybackStats(
      bufferedFrames: _outputBuffer.length,
      capacityFrames: _overflowPolicy == AudioIoOverflowPolicy.grow
          ? _playbackMaxSamples
          : _playbackTargetSamples,
      droppedFrames: _droppedFrames,
    );
  }

  /// Resolves the playback FIFO bounds (in samples) from the requested
  /// durations and the live AudioContext rate. Mirrors the native defaults:
  /// 10 s initial, grown to max(initial, 60 s).
  void _resolvePlaybackBounds(double sampleRate) {
    final targetSeconds =
        _requestedPlaybackSeconds ?? _defaultPlaybackSeconds;
    final requestedMax = _requestedMaxPlaybackSeconds ??
        (targetSeconds > _defaultMaxPlaybackSeconds
            ? targetSeconds
            : _defaultMaxPlaybackSeconds);
    // Defensive: the growth ceiling can never be below the initial size.
    final maxSeconds =
        requestedMax > targetSeconds ? requestedMax : targetSeconds;
    _playbackTargetSamples = (targetSeconds * sampleRate).round();
    _playbackMaxSamples = (maxSeconds * sampleRate).round();
  }

  /// Appends decoded float samples to the playback FIFO, applying the
  /// configured overflow policy and counting any dropped frames so
  /// [playbackStats] can surface them instead of losing audio silently.
  void _enqueueOutput(List<double> samples) {
    switch (_overflowPolicy) {
      case AudioIoOverflowPolicy.grow:
      case AudioIoOverflowPolicy.dropNewest:
        final cap = _overflowPolicy == AudioIoOverflowPolicy.grow
            ? _playbackMaxSamples
            : _playbackTargetSamples;
        final room = cap - _outputBuffer.length;
        if (samples.length <= room) {
          _outputBuffer.addAll(samples);
        } else {
          if (room > 0) {
            _outputBuffer.addAll(samples.take(room));
          }
          _droppedFrames += samples.length - (room > 0 ? room : 0);
        }
        break;
      case AudioIoOverflowPolicy.dropOldest:
        _outputBuffer.addAll(samples);
        while (_outputBuffer.length > _playbackTargetSamples) {
          _outputBuffer.removeFirst();
          _droppedFrames++;
        }
        break;
    }
  }

  /// Maps a requested frame duration to a ScriptProcessorNode buffer size.
  ///
  /// The Web Audio API only accepts power-of-two buffers in
  /// [`_minBufferSize`, `_maxBufferSize`]. An explicit `frameDurationMs`
  /// request (>= 20ms) is honoured by picking the nearest valid buffer size;
  /// the sub-10ms native latency presets — which the main-thread
  /// ScriptProcessor cannot deliver — fall back to the default buffer.
  int _resolveBufferSize(double sampleRate) {
    final requested = _requestedFrameDuration;
    if (requested == null || requested < _minHonouredFrameDuration) {
      return _defaultBufferSize;
    }
    final idealSamples = requested * sampleRate;
    var best = _minBufferSize;
    for (var size = _minBufferSize; size <= _maxBufferSize; size *= 2) {
      if ((size - idealSamples).abs() < (best - idealSamples).abs()) {
        best = size;
      }
    }
    return best;
  }
}

Uint8List _float32ListToPcm16Le(List<double> samples) {
  final bytes = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0);
    bytes.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

List<double> _pcm16LeToFloat32(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final samples = List<double>.filled(bytes.length ~/ 2, 0.0);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32767.0;
  }
  return samples;
}

AudioIoImpl createAudioIoImpl() => AudioIoWeb();
