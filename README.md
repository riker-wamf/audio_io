# audio_io

A Flutter plugin for cross-platform real-time audio streaming. Provides low-latency audio input/output with simple Stream-based API for audio processing, recording, and visualization.

## Features

- Real-time audio streaming from microphone to Flutter
- Audio output/playback through speakers
- Cross-platform support (iOS, macOS, Android, Web, Linux, Windows)
- Simple Stream-based API
- Configurable audio latency modes
- Consistent data format across all platforms (Float64, 48kHz, mono)
- Low-latency audio processing
- Volume level monitoring

## Platform Support

| Platform | Status | Implementation |
|----------|--------|---------------|
| iOS      | ✅ Supported | Native (AVAudioEngine) |
| macOS    | ✅ Supported | Native (AVAudioEngine) |
| Android  | ✅ Supported | FFI (miniaudio) |
| Web      | ✅ Supported | Web Audio API |
| Linux    | ✅ Supported | FFI (miniaudio) |
| Windows  | ✅ Supported | FFI (miniaudio) |

## Getting Started

### Installation

Add `audio_io` to your `pubspec.yaml`:

```yaml
dependencies:
  audio_io: ^0.3.0
```

### iOS Setup

Add microphone usage description to your `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs access to the microphone for audio processing.</string>
```

### macOS Setup

1. Add microphone usage description to your `macos/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs access to the microphone for audio processing.</string>
```

2. Enable audio input in your entitlements files:
   - `macos/Runner/DebugProfile.entitlements`
   - `macos/Runner/Release.entitlements`

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

### Android Setup

Add microphone permission to your `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

The plugin will automatically request the permission at runtime when needed.

### Usage

```dart
import 'package:audio_io/audio_io.dart';

// Get the audio instance
final audioIo = AudioIo.instance;

// Configure latency (optional)
await audioIo.requestLatency(AudioIoLatency.Balanced);

// Start audio processing
await audioIo.start();

// Listen to input audio stream
audioIo.input.listen((audioData) {
  // Process audio data (List<double>)
  print('Received ${audioData.length} samples');
  
  // Calculate volume level (RMS)
  final sum = audioData.fold<double>(
    0.0, (sum, sample) => sum + sample * sample);
  final rms = sqrt(sum / audioData.length);
});

// Send audio to output (echo example)
audioIo.input.listen((data) {
  audioIo.output.add(data);
});

// Stop audio processing
await audioIo.stop();
```

### Latency Configuration

The plugin supports three latency modes:

```dart
enum AudioIoLatency {
  Realtime,  // Lowest latency (~1.5ms buffer)
  Balanced,  // Balanced latency/CPU (~3ms buffer)
  Powersave, // Lower CPU usage (~6ms buffer)
}

// Set before starting audio
await audioIo.requestLatency(AudioIoLatency.Realtime);
```

### Playback Buffer (real-time streaming / Gemini Live)

The playback (output) queue is configurable for streaming AI use, where audio
arrives from the network in bursts. Supported on iOS, macOS and web.

```dart
await AudioIo.instance.startWith(const AudioIoConfig(
  sampleRate: AudioIoSampleRate.rate16000,
  format: AudioIoFormat.pcm16,
  // Latency vs. underrun protection. Small = responsive conversation;
  // large = safer for long responses. null keeps the 10 s default.
  playbackBufferDuration: Duration(seconds: 2),
  // When audio arrives faster than it plays (e.g. a 40 s response delivered
  // in ~5 s), grow the buffer to absorb it — up to this ceiling.
  maxPlaybackBufferDuration: Duration(seconds: 60),
  // grow (default) | dropOldest | dropNewest. Drops are counted, never silent.
  playbackOverflow: AudioIoOverflowPolicy.grow,
));

// Barge-in: the user interrupted, so drop the stale queued audio at once
// (capture/playback keep running). e.g. on a Gemini Live `interrupted` event.
await AudioIo.instance.flushPlayback();

// Observe playback latency and detect overflow drops.
final stats = await AudioIo.instance.playbackStats();
if (stats != null && (stats.droppedFrames ?? 0) > 0) {
  // Audio was dropped — increase the buffer or check the network.
}
```

> Android, Linux and Windows (FFI/miniaudio) accept these options for API
> symmetry, but configurable sizing, `flushPlayback()` and `playbackStats()`
> are not yet wired through the C layer (tracked as a follow-up).

## Audio Format

All platforms use a consistent audio format:

- **Sample Rate**: 48kHz (may adapt to device capabilities)
- **Channels**: Mono (1 channel)
- **Data Type**: Double precision floats (Float64/double)
- **Stream Format**: Chunks of audio samples as `List<double>`
- **Internal Processing**: Platform-specific (Float32 on native platforms)

## Requirements

- Dart SDK: >=3.0.0 <4.0.0
- Flutter: >=3.10.0
- iOS: 12.0 or higher
- macOS: 10.15 or higher

## License

See LICENSE file for details.