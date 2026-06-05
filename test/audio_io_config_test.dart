import 'package:flutter_test/flutter_test.dart';
import 'package:audio_io/audio_io.dart';

void main() {
  group('AudioIoConfig', () {
    test('defaults to rejecting a web sample-rate mismatch', () {
      const config = AudioIoConfig();
      expect(config.allowSampleRateMismatch, isFalse);
      expect(config.sampleRate, AudioIoSampleRate.rate48000);
      expect(config.format, AudioIoFormat.float64);
    });

    test('allowSampleRateMismatch can be opted into', () {
      const config = AudioIoConfig(
        sampleRate: AudioIoSampleRate.rate16000,
        format: AudioIoFormat.pcm16,
        allowSampleRateMismatch: true,
      );
      expect(config.allowSampleRateMismatch, isTrue);
      expect(config.sampleRate.hz, 16000);
      expect(config.format.value, AudioIoFormat.pcm16.value);
    });

    test('frameDurationMs is validated to the 20-100 ms range', () {
      expect(() => AudioIoConfig(frameDurationMs: 50), returnsNormally);
      expect(
        () => AudioIoConfig(frameDurationMs: 10),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => AudioIoConfig(frameDurationMs: 200),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('AudioIoConfig playback buffer', () {
    test('defaults: null durations and grow overflow policy', () {
      const config = AudioIoConfig();
      expect(config.playbackBufferDuration, isNull);
      expect(config.maxPlaybackBufferDuration, isNull);
      expect(config.playbackOverflow, AudioIoOverflowPolicy.grow);
      // Null durations let the native layer apply its own default.
      expect(config.playbackBufferSeconds, isNull);
      expect(config.maxPlaybackBufferSeconds, isNull);
    });

    test('converts configured durations to seconds for the native layer', () {
      const config = AudioIoConfig(
        playbackBufferDuration: Duration(milliseconds: 200),
        maxPlaybackBufferDuration: Duration(seconds: 30),
        playbackOverflow: AudioIoOverflowPolicy.dropOldest,
      );
      expect(config.playbackBufferSeconds, closeTo(0.2, 1e-9));
      expect(config.maxPlaybackBufferSeconds, closeTo(30.0, 1e-9));
      expect(config.playbackOverflow, AudioIoOverflowPolicy.dropOldest);
    });

    test('a real-time (small) and a long-response (large) config both build',
        () {
      // Real-time conversation: small buffer, stay current.
      const realtime = AudioIoConfig(
        playbackBufferDuration: Duration(milliseconds: 200),
        playbackOverflow: AudioIoOverflowPolicy.dropOldest,
      );
      expect(realtime.playbackBufferSeconds, closeTo(0.2, 1e-9));
      // Long responses: large buffer, grow to absorb a burst.
      const longResponse = AudioIoConfig(
        playbackBufferDuration: Duration(seconds: 15),
        maxPlaybackBufferDuration: Duration(seconds: 90),
      );
      expect(longResponse.playbackBufferSeconds, closeTo(15.0, 1e-9));
      expect(longResponse.maxPlaybackBufferSeconds, closeTo(90.0, 1e-9));
      expect(longResponse.playbackOverflow, AudioIoOverflowPolicy.grow);
    });
  });

  group('AudioIoOverflowPolicy', () {
    test('values match the native (Swift) raw values', () {
      // The Dart enum.value is sent over the method channel and decoded by
      // OverflowPolicy(rawValue:) on iOS/macOS — these must stay in lockstep.
      expect(AudioIoOverflowPolicy.grow.value, 0);
      expect(AudioIoOverflowPolicy.dropOldest.value, 1);
      expect(AudioIoOverflowPolicy.dropNewest.value, 2);
      // Index order is also used by the web impl (values[index]).
      expect(AudioIoOverflowPolicy.values.map((p) => p.value),
          [0, 1, 2]);
    });
  });

  group('AudioIoPlaybackStats', () {
    test('parses a native stats map', () {
      final stats = AudioIoPlaybackStats.fromMap({
        'bufferedFrames': 8000,
        'capacityFrames': 160000,
        'droppedFrames': 240,
      });
      expect(stats.bufferedFrames, 8000);
      expect(stats.capacityFrames, 160000);
      expect(stats.droppedFrames, 240);
    });

    test('tolerates missing/null fields', () {
      final stats = AudioIoPlaybackStats.fromMap({'bufferedFrames': 100});
      expect(stats.bufferedFrames, 100);
      expect(stats.capacityFrames, 0);
      expect(stats.droppedFrames, isNull);
    });

    test('bufferedDuration converts frames to time at a sample rate', () {
      const stats = AudioIoPlaybackStats(
        bufferedFrames: 16000,
        capacityFrames: 160000,
      );
      expect(stats.bufferedDuration(16000), const Duration(seconds: 1));
      // Guards against divide-by-zero.
      expect(stats.bufferedDuration(0), Duration.zero);
    });
  });
}
