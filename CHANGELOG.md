## 0.0.1
Kiss release
Input from mic at fixed sample rate and buffer size, no output

## 0.0.2
Kiss MVP release

Input from mic at fixed sample rate and buffer size, output fixed at mono at the same sample rate as input.
Simple quick and dirty ringbuffer for output (needs optimisation)

## 0.0.3
Bugfix
Fix 32-64bit mismatch of data.

## 0.0.4
Improvement
Allow muliple listeners on audio input

## 0.0.5
Bugfix
Thread safety - memory leak fixed :)

## 0.0.6
Improvement
Main thread call for sink removed (attempt to reduce latency introduced in 0.0.5)

## 0.0.7
Rollback 0.0.6

## 0.0.8
Improvement
Handle audio session changes
Reset audio when entering foreground

## 0.0.9
Improvement
Handle audio interruptions
Using simpler binary message system to send data (2x cpu optimisation)
Replaced invoking method with binary message for output audio
Less format conversions when sending data in and out
Prep work for upcoming buffer and samplerate selection features

## 0.1.0
New Interface
Added inteface for getting format and buffer size selection (audio frame size)
Using serial queue for read and writes to buffer

## 0.1.1
Performance
Fixing Dart side audio format to double (everything is 64bit these days, 64bit is great for processing)
Optimised data conversion 

## 0.1.2
Bugfix
Fix bug which stopped audio when coming back from background

## 0.1.3
Bugfix
Fixed issue with route swapping from speaker to headphones

## 0.1.4
Bugfix
Better way to detect changes in audio format, removed old methods

## 0.1.5
Bugfix
Using detected input sample rate rather than fixed sample rate

## 0.1.6
Cleanup
Added null safety 

## 0.1.7
Performance improvement

## 0.1.8
Fix dangling pointer

## 0.1.9
Small performance improvement
Remove fonts from example
Bump SDK version

## 0.2.0
Major Update
- Added macOS platform support with full audio input/output capabilities
- Updated minimum SDK requirements: Dart >=3.4.0, Flutter >=3.22.0
- Fixed ring buffer infinite recursion bug in macOS implementation
- Added proper entitlements configuration for macOS microphone access
- Updated documentation with platform-specific setup instructions
- Improved cross-platform compatibility

## 0.3.0
Multi-Platform Release
- Added Android platform support using miniaudio C++ library via FFI
- Added Web platform support using Web Audio API
- Added Linux platform support using miniaudio via FFI
- Added Windows platform support using miniaudio via FFI
- Implemented configurable audio latency (Realtime/Balanced/Powersave modes)
- Added real-time volume meter visualization in example app
- Standardized data format across all platforms (Float64, 48kHz, mono)
- Fixed microphone permissions handling on Android
- Improved FFI implementation with proper memory management
- Added comprehensive .gitignore for C/C++ build artifacts
- Fixed all analyzer warnings and improved code quality
- Updated minimum SDK requirements: Dart >=3.0.0, Flutter >=3.10.0

Platform Support:
- iOS ✅ (Native Swift/AVAudioEngine)
- macOS ✅ (Native Swift/AVAudioEngine)  
- Android ✅ (FFI/miniaudio)
- Web ✅ (Web Audio API)
- Linux ✅ (FFI/miniaudio)
- Windows ✅ (FFI/miniaudio)

## Unreleased
Configurable, flushable, overflow-aware playback queue (real-time AI use)
- `AudioIoConfig.playbackBufferDuration` makes the playback buffer size
  configurable instead of a hardcoded 10 s, trading latency vs. underrun
  protection (iOS, macOS, web). `null` keeps the 10 s default.
- `AudioIo.flushPlayback()` drops queued, not-yet-played output audio for
  barge-in / interrupt (e.g. on a Gemini Live `interrupted` event) without
  stopping capture/playback (iOS, macOS, web).
- Burst overflow (e.g. a 40 s response delivered in ~5 s) is no longer
  silently dropped. New `AudioIoOverflowPolicy` (`grow` (default),
  `dropOldest`, `dropNewest`) defines the behaviour; under `grow` the buffer
  expands up to `maxPlaybackBufferDuration` (default 60 s). Drops are counted
  and surfaced via `AudioIo.playbackStats()` instead of being silent.
- Gemini Live example wired for barge-in and a small low-latency playback
  buffer that grows for long responses.
- Android/Linux/Windows (FFI/miniaudio): the new knobs are accepted for API
  symmetry but not yet wired through the C layer (flush is a no-op, stats
  return null) — tracked as a follow-up.
- Needs on-device verification on iOS/macOS (no host Swift toolchain in CI).