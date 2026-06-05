import AVFoundation
import Flutter

extension Data {
    init<T>(fromArray values: [T]) {
        self = values.withUnsafeBytes { Data($0) }
    }

    func toArray<T>(type _: T.Type) -> [T] where T: ExpressibleByIntegerLiteral {
        var array = [T](repeating: 0, count: count / MemoryLayout<T>.stride)
        _ = array.withUnsafeMutableBytes { copyBytes(to: $0) }
        return array
    }
}

private enum _Constants {
    static let defaultSampleRate = 48000.0
    static let workspaceSamples = 100_000
    static let defaultFrameDuration = 0.003
    static let defaultMaxFrameJitter = 4.0
    static let processingQueueName = "SwiftAudioIoPluginQueue"
    static let formatFloat64 = "float64"
    static let formatPcm16 = "pcm16"
    static let pcm16ScaleFactor: Float = 32767.0
    // Playback ring-buffer defaults (seconds of audio). The initial size is the
    // latency-vs-underrun knob; the buffer may grow up to the max under the
    // `grow` overflow policy. Mirrors the Dart-side defaults.
    static let defaultPlaybackSeconds = 10.0
    static let defaultMaxPlaybackSeconds = 60.0
    // Absolute floor so a tiny configured buffer still holds a few render
    // quanta. Replaces the old fixed 131072-sample floor, which (at low rates)
    // was several seconds and would have defeated small-latency configs.
    static let minPlaybackSamples = 2048
}

// How the playback queue reacts when audio arrives faster than it drains.
// Raw values match AudioIoOverflowPolicy on the Dart side.
enum OverflowPolicy: Int {
    case grow = 0
    case dropOldest = 1
    case dropNewest = 2
}

enum Methods: String {
    case start
    case stop
    case requestFrameDuration
    case getFrameDuration
    case requestFormat
    case getFormat
    case flushPlayback
    case getPlaybackStats
}

enum Channels: String {
    case inputChannelName = "com.wearemobilefirst.audio_io.inputAudio"
    case outputChannelName = "com.wearemobilefirst.audio_io.outputAudio"
    case methodChannelName = "com.wearemobilefirst.audio_io"
}

enum AudioDataTypes: String {
    case double
    case float
    case int
    case int16
}

enum _AudioFormat {
    static let sampleRate = "sampleRate"
    static let dataType = "type"
    static let channels = "channels"
    static let input = "input"
    static let output = "output"
    static let format = "format"
}

public class SwiftAudioIoPlugin: NSObject, FlutterPlugin {
    let engine = AVAudioEngine()
    var _binaryMessenger: FlutterBinaryMessenger?
    var _frameDuration = _Constants.defaultFrameDuration
    var _sampleRate = _Constants.defaultSampleRate
    var _requestedSampleRate = _Constants.defaultSampleRate
    var _requestedFormat = _Constants.formatFloat64
    var buffer = RingBuffer<Float>(count: 0)
    let maxFrameJitter = _Constants.defaultMaxFrameJitter
    let queue = DispatchQueue(label: _Constants.processingQueueName)
    var _isRunning = false
    var _isPipelineSetup = false
    var _resetting = false
    // Playback queue configuration (see _Constants / OverflowPolicy).
    var _playbackBufferSeconds = _Constants.defaultPlaybackSeconds
    var _playbackMaxSeconds = _Constants.defaultMaxPlaybackSeconds
    var _overflowPolicy: OverflowPolicy = .grow
    // Cumulative frames dropped on overflow since the last start(). Surfaced to
    // Dart via getPlaybackStats — the explicit signal that replaces the old
    // silent tail-drop. Mutated only on `queue`.
    var _droppedFrames = 0

    private var sourceNode: AVAudioSourceNode?
    private var inputAudioConverter: AVAudioConverter?
    // Sample rate / format the live pipeline (converter, source node, input tap)
    // was actually built for. Used to detect when a stop() -> startWith(...)
    // changes the request and the pipeline must be torn down and rebuilt.
    private var _pipelineSampleRate: Double?
    private var _pipelineFormat: String?

    private func createSourceNode() -> AVAudioSourceNode {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: _sampleRate, channels: 1, interleaved: false)!
        return AVAudioSourceNode(format: format, renderBlock: { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            self.queue.sync {
                for buffer in ablPointer {
                    let buf: UnsafeMutableBufferPointer<Float> = UnsafeMutableBufferPointer(buffer)
                    var i = 0
                    while i < frameCount {
                        buf[i] = self.buffer.read() ?? 0
                        i += 1
                    }
                }
            }
            return noErr
        })
    }

    // Captured mic audio arrives at the hardware rate via the input tap and is
    // resampled down to the requested rate by `inputAudioConverter` before it is
    // converted to PCM16/Float64 and pushed to Flutter. setPreferredSampleRate is
    // only a request on iOS — the session may run the hardware at a different
    // rate — so the conversion must happen explicitly here; otherwise the mic can
    // stream at the device rate (e.g. 48 kHz) regardless of what was requested.
    private func handleCapturedBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter = inputAudioConverter else { return }
        let outputFormat = converter.outputFormat

        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 64
        guard capacity > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, inStatus in
            if consumed {
                inStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error || error != nil {
            print("Input conversion error \(String(describing: error))")
            return
        }

        let sampleCount = Int(outputBuffer.frameLength)
        guard sampleCount > 0, let channel = outputBuffer.floatChannelData else { return }
        let samples = channel[0]

        let data: Data
        if _requestedFormat == _Constants.formatPcm16 {
            var int16Samples = [Int16](repeating: 0, count: sampleCount)
            var i = 0
            while i < sampleCount {
                let clamped = min(max(samples[i], -1.0), 1.0)
                int16Samples[i] = Int16(clamped * _Constants.pcm16ScaleFactor)
                i += 1
            }
            data = Data(fromArray: int16Samples)
        } else {
            var doubleSamples = [Double](repeating: 0.0, count: sampleCount)
            var i = 0
            while i < sampleCount {
                doubleSamples[i] = Double(samples[i])
                i += 1
            }
            data = Data(fromArray: doubleSamples)
        }

        _binaryMessenger?.send(onChannel: Channels.inputChannelName.rawValue, message: data)
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: Channels.methodChannelName.rawValue, binaryMessenger: registrar.messenger())
        let instance = SwiftAudioIoPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance._binaryMessenger = registrar.messenger()
        instance._binaryMessenger?.setMessageHandlerOnChannel(Channels.outputChannelName.rawValue, binaryMessageHandler: { data, _ in
            guard let data = data else {
                return
            }
            instance.queue.async {
                if instance._requestedFormat == _Constants.formatPcm16 {
                    let int16s: [Int16] = data.toArray(type: Int16.self)
                    let floats = int16s.map { Float($0) / _Constants.pcm16ScaleFactor }
                    instance.appendPlayback(floats)
                } else {
                    let doubles: [Double] = data.toArray(type: Double.self)
                    let floats = doubles.map { Float($0) }
                    instance.appendPlayback(floats)
                }
            }
        })

        NotificationCenter.default.addObserver(instance, selector: #selector(handleConfigChange), name: NSNotification.Name.AVAudioEngineConfigurationChange, object: nil)
        NotificationCenter.default.addObserver(instance, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(instance, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case Methods.start.rawValue:
            // Plain start() carries no args. Reset to defaults first so a prior
            // startWith(pcm16/non-default rate) doesn't leak its requested format
            // or sample rate into a subsequent default start().
            _requestedSampleRate = _Constants.defaultSampleRate
            _requestedFormat = _Constants.formatFloat64
            _playbackBufferSeconds = _Constants.defaultPlaybackSeconds
            _playbackMaxSeconds = _Constants.defaultMaxPlaybackSeconds
            _overflowPolicy = .grow
            if let args = call.arguments as? [String: Any] {
                // Dart sends `sampleRate` (int hz) and `format` (int 0=float64, 1=pcm16),
                // both of which arrive as NSNumber over the method channel — not Double/String.
                // Casting an int-backed NSNumber `as? String` is always nil, so the previous
                // code silently fell back to float64 and PCM16 never activated on Apple platforms.
                if let sampleRate = args["sampleRate"] as? NSNumber {
                    _requestedSampleRate = sampleRate.doubleValue
                }
                if let format = args["format"] as? NSNumber {
                    _requestedFormat = format.intValue == 1 ? _Constants.formatPcm16 : _Constants.formatFloat64
                } else if let format = args["format"] as? String {
                    _requestedFormat = format
                }
                // Playback queue config. null on the Dart side => key absent or
                // NSNull => keep the default.
                if let playbackSeconds = args["playbackBufferSeconds"] as? NSNumber {
                    _playbackBufferSeconds = playbackSeconds.doubleValue
                }
                if let maxPlaybackSeconds = args["maxPlaybackBufferSeconds"] as? NSNumber {
                    _playbackMaxSeconds = maxPlaybackSeconds.doubleValue
                }
                if let policy = args["overflowPolicy"] as? NSNumber,
                   let parsed = OverflowPolicy(rawValue: policy.intValue) {
                    _overflowPolicy = parsed
                }
            }
            start()
            result(nil)
        case Methods.stop.rawValue:
            stop()
            result(nil)
        case Methods.requestFrameDuration.rawValue:
            if let requested = call.arguments as? Double {
                _frameDuration = requested
            }
            result(nil)
        case Methods.getFrameDuration.rawValue:
            result(_frameDuration)
        case Methods.getFormat.rawValue:
            result(getFormat())
        case Methods.flushPlayback.rawValue:
            // Barge-in: drop everything still queued for playback so stale audio
            // stops immediately. clear() only resets the read/write indices, so
            // it is cheap and safe to run synchronously w.r.t. the render block
            // (both serialize on `queue`).
            queue.sync { buffer.clear() }
            result(nil)
        case Methods.getPlaybackStats.rawValue:
            var stats: [String: Any] = [:]
            queue.sync {
                stats = [
                    "bufferedFrames": buffer.count,
                    "capacityFrames": buffer.capacity,
                    "droppedFrames": _droppedFrames,
                ]
            }
            result(stats)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func stop() {
        print("Stop Audio Engine")
        engine.stop()
        _isRunning = false
    }

    public func start() {
        print("Start Audio Engine")
        _sampleRate = _requestedSampleRate
        // Output is fed from the network (Gemini) in bursts, so the playback ring
        // buffer must hold seconds — not milliseconds — of audio to avoid
        // underruns. The initial size is caller-configurable (latency vs.
        // underrun protection); under the `grow` policy appendPlayback() lets it
        // expand up to _playbackMaxSeconds when a burst overflows. Sized at the
        // requested rate because the sourceNode renders at the requested rate and
        // the mixer resamples up to the hardware rate.
        let bufferSize = max(Int(_sampleRate * _playbackBufferSeconds), _Constants.minPlaybackSamples)
        buffer = RingBuffer<Float>(count: bufferSize)
        _droppedFrames = 0

        do {
            // `.voiceChat` mode engages the system's two-way voice tuning and is the
            // session-level half of acoustic echo cancellation. Paired with the
            // voice-processing I/O unit enabled in setupPipelineIfNeeded(), it stops
            // full-duplex speaker output (e.g. Gemini Live's playback) from leaking
            // into the mic and making the model interrupt/loop when no earphones are
            // used. `.allowBluetooth` (HFP) is added alongside `.allowBluetoothA2DP`
            // so a Bluetooth headset still routes the duplex stream.
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord,
                                                            mode: .voiceChat,
                                                            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(_frameDuration)
            try AVAudioSession.sharedInstance().setPreferredSampleRate(_requestedSampleRate)
        } catch {
            print("Session config Error")
            return
        }

        do {
            try setupPipelineIfNeeded()
        } catch {
            print("Audio pipeline error \(error)")
            return
        }

        do {
            try engine.start()
            _isRunning = true
        } catch {
            print("Audio start error")
        }
    }

    public func setupPipelineIfNeeded() throws {
        // stop() deliberately leaves the pipeline attached so a same-config
        // restart is cheap. But it also means a later startWith(newRate/format)
        // would otherwise keep the stale converter, source-node format, and
        // input tap while getFormat() reports the new request. Tear down and
        // rebuild whenever the requested rate/format no longer matches the
        // pipeline that is actually wired up.
        if _isPipelineSetup,
           _pipelineSampleRate != _sampleRate || _pipelineFormat != _requestedFormat {
            print("setupPipeline: config changed (\(_pipelineSampleRate ?? -1)/\(_pipelineFormat ?? "?") -> \(_sampleRate)/\(_requestedFormat)), rebuilding")
            // Never detach nodes from a running engine. The usual stop() ->
            // startWith(...) path already has the engine stopped; this guards the
            // case where startWith(...) is called again without a prior stop().
            engine.stop()
            _isRunning = false
            detachPipeline()
        }

        if !_isPipelineSetup {
            print("setupPipeline")
            let input = engine.inputNode
            let output = engine.mainMixerNode

            // Enable Apple's voice-processing I/O unit (VPIO) on the input node.
            // This is the acoustic-echo-cancellation engine: it references the
            // engine's render output (the sourceNode playing Gemini's audio) and
            // subtracts it from the captured mic signal, so full-duplex playback on
            // the built-in speaker is no longer picked up by the mic. Must be set
            // while the engine is stopped and *before* querying the input format,
            // because enabling VPIO changes the node's hardware output format.
            // Enabling on the input node also enables it on the output node (they
            // share one Voice-Processing AU). Failure is non-fatal — fall back to
            // the plain duplex path rather than aborting start().
            do {
                if !input.isVoiceProcessingEnabled {
                    try input.setVoiceProcessingEnabled(true)
                }
            } catch {
                print("setupPipeline: voice processing (echo cancellation) unavailable: \(error)")
            }

            // Keep the engine at the hardware rate and convert at the boundaries
            // (the pattern Apple recommends): _sampleRate stays at the *requested*
            // rate so Flutter receives the rate it asked for. Previously
            // `_sampleRate` was overwritten with `inputFormat.sampleRate`, which
            // forced the whole pipeline to the device rate — playback ran at the
            // wrong speed and the mic streamed at the device rate while Gemini
            // expects the requested (e.g. 16 kHz) rate.
            let hardwareInputFormat = input.outputFormat(forBus: 0)
            guard hardwareInputFormat.sampleRate > 0 else {
                throw NSError(domain: Channels.methodChannelName.rawValue, code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Input device unavailable (sampleRate 0). Check microphone permission/entitlement."])
            }
            let processingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: _sampleRate,
                                                 channels: 1,
                                                 interleaved: false)!

            // Output: Dart writes requested-rate float into the ring buffer; the
            // sourceNode renders at the requested rate and the main mixer
            // resamples up to the hardware output rate.
            let sourceNode = createSourceNode()
            engine.attach(sourceNode)
            engine.connect(sourceNode, to: output, format: processingFormat)
            self.sourceNode = sourceNode

            // Input: tap the mic at the hardware rate and resample down to the
            // requested rate with a persistent converter (state carries across
            // callbacks, so there are no resampling discontinuities).
            guard let converter = AVAudioConverter(from: hardwareInputFormat, to: processingFormat) else {
                throw NSError(domain: Channels.methodChannelName.rawValue, code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "Could not create input converter \(hardwareInputFormat) -> \(processingFormat)"])
            }
            inputAudioConverter = converter
            input.installTap(onBus: 0, bufferSize: 4096, format: hardwareInputFormat) { [weak self] buffer, _ in
                self?.handleCapturedBuffer(buffer)
            }

            _isPipelineSetup = true
            _pipelineSampleRate = _sampleRate
            _pipelineFormat = _requestedFormat
            print("setupPipeline complete (hwIn=\(hardwareInputFormat.sampleRate) requested=\(_sampleRate))")
        }
    }

    public func detachPipeline() {
        print("detachPipeline")
        engine.inputNode.removeTap(onBus: 0)
        if let sourceNode = sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        inputAudioConverter = nil
        _pipelineSampleRate = nil
        _pipelineFormat = nil
        _isPipelineSetup = false
    }

    @objc func handleConfigChange(notification _: NSNotification) {
        print("handleConfigChange:")
        resetAudio()
    }

    @objc func handleInterruption(notification: NSNotification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              _isRunning
        else {
            return
        }
        switch type {
        case .began:
            print("handleInterruption: began")
        case .ended:
            print("handleInterruption: ended")
        default: ()
        }
    }

    @objc func handleRouteChange(notification: NSNotification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else {
            return
        }
        switch reason {
        case .newDeviceAvailable:
            print("newDeviceAvailable:")
        case .oldDeviceUnavailable:
            print("oldDeviceAvailable:")
        case .routeConfigurationChange:
            print("routeConfigurationChange:")
        case .categoryChange:
            print("routeConfigurationChange:")
        default: ()
            print("handleRouteChange:")
            print(reasonValue)
        }
    }

    public func resetAudio() {
        if _isRunning && !_resetting {
            _resetting = true
            print("Resetting Audio Engine")
            engine.stop()
            detachPipeline()
            DispatchQueue.main.async {
                self.start()
                self._resetting = false
            }
        }
    }

    // Enqueues decoded playback samples, applying the configured overflow
    // policy when the ring buffer is full. Replaces the previous
    // `_ = buffer.writeBlock(...)`, which silently dropped the *entire*
    // overflowing block — so a 40 s response delivered in ~5 s lost its tail
    // with no signal. Must be called on `queue`.
    private func appendPlayback(_ floats: [Float]) {
        if buffer.writeBlock(floats) { return }

        switch _overflowPolicy {
        case .grow:
            // Expand toward _playbackMaxSeconds to absorb the burst; only drop
            // once even the ceiling can't hold it.
            let maxSamples = max(Int(_sampleRate * _playbackMaxSeconds), buffer.capacity)
            if buffer.capacity < maxSamples {
                let needed = buffer.count + floats.count
                let target = min(maxSamples, max(needed, buffer.capacity * 2))
                buffer.resize(to: target)
                if buffer.writeBlock(floats) { return }
            }
            _droppedFrames += floats.count
        case .dropOldest:
            // Keep the buffer current by discarding the oldest queued audio.
            if floats.count >= buffer.capacity {
                // The block alone exceeds the whole buffer: keep only its tail.
                _droppedFrames += buffer.count
                buffer.clear()
                let tail = Array(floats.suffix(buffer.capacity))
                _droppedFrames += floats.count - tail.count
                _ = buffer.writeBlock(tail)
            } else {
                let overflow = (buffer.count + floats.count) - buffer.capacity
                if overflow > 0 {
                    _droppedFrames += buffer.discardOldest(overflow)
                }
                _ = buffer.writeBlock(floats)
            }
        case .dropNewest:
            // Historical behaviour, now counted rather than silent.
            _droppedFrames += floats.count
        }
    }

    public func getFormat() -> [String: Any] {
        let dataType = _requestedFormat == _Constants.formatPcm16
            ? AudioDataTypes.int16.rawValue
            : AudioDataTypes.double.rawValue

        let inputDesc: [String: Any] = [_AudioFormat.dataType: dataType,
                                        _AudioFormat.channels: 1,
                                        _AudioFormat.sampleRate: _sampleRate,
                                        _AudioFormat.format: _requestedFormat]

        let outputDesc: [String: Any] = [_AudioFormat.dataType: dataType,
                                         _AudioFormat.channels: 1,
                                         _AudioFormat.sampleRate: _sampleRate,
                                         _AudioFormat.format: _requestedFormat]

        return [_AudioFormat.input: inputDesc, _AudioFormat.output: outputDesc]
    }
}

public struct RingBuffer<T> {
    fileprivate var array: [T?]
    fileprivate var readIndex = 0
    fileprivate var writeIndex = 0

    public init(count: Int) {
        array = [T?](repeating: nil, count: count)
    }

    public mutating func write(_ element: T) -> Bool {
        if !isFull {
            array[writeIndex % array.count] = element
            writeIndex += 1
            return true
        } else {
            return false
        }
    }

    public mutating func writeBlock(_ block: [T]) -> Bool {
        let count = block.count
        guard availableSpaceForWriting >= count else {
            return false
        }

        let writeStartIndex = writeIndex % array.count

        if writeStartIndex + count <= array.count {
            for i in 0 ..< count {
                array[writeStartIndex + i] = block[i]
            }
        } else {
            let firstPartCount = array.count - writeStartIndex
            for i in 0 ..< firstPartCount {
                array[writeStartIndex + i] = block[i]
            }
            for i in 0 ..< count - firstPartCount {
                array[i] = block[firstPartCount + i]
            }
        }

        writeIndex += count
        return true
    }

    public mutating func read() -> T? {
        if !isEmpty {
            let element = array[readIndex % array.count]
            readIndex += 1
            return element
        } else {
            return nil
        }
    }

    public mutating func readBlock(count: Int) -> [T?]? {
        if availableSpaceForReading >= count {
            var result = [T?](repeating: nil, count: count)
            for i in 0 ..< count {
                result[i] = array[(readIndex + i) % array.count]
            }
            readIndex += count
            return result
        }
        return nil
    }

    public mutating func clear() {
        readIndex = 0
        writeIndex = 0
    }

    /// Total backing capacity in elements.
    public var capacity: Int {
        return array.count
    }

    /// Number of written-but-unread elements currently queued.
    public var count: Int {
        return writeIndex - readIndex
    }

    /// Discards up to `n` of the oldest unread elements; returns how many were
    /// actually dropped. Used by the dropOldest overflow policy.
    public mutating func discardOldest(_ n: Int) -> Int {
        let toDrop = min(max(n, 0), count)
        readIndex += toDrop
        return toDrop
    }

    /// Reallocates to `newCapacity`, preserving the most recent unread elements
    /// (and resetting the indices). Used by the grow overflow policy. Safe to
    /// shrink, in which case only the newest `newCapacity` elements are kept.
    public mutating func resize(to newCapacity: Int) {
        guard newCapacity > 0 else { return }
        let unread = count
        let keep = min(unread, newCapacity)
        var newArray = [T?](repeating: nil, count: newCapacity)
        if keep > 0, array.count > 0 {
            let start = writeIndex - keep
            for i in 0 ..< keep {
                newArray[i] = array[((start + i) % array.count + array.count) % array.count]
            }
        }
        array = newArray
        readIndex = 0
        writeIndex = keep
    }

    fileprivate var availableSpaceForReading: Int {
        return writeIndex - readIndex
    }

    public var isEmpty: Bool {
        return availableSpaceForReading == 0
    }

    fileprivate var availableSpaceForWriting: Int {
        return array.count - availableSpaceForReading
    }

    public var isFull: Bool {
        return availableSpaceForWriting == 0
    }
}

public extension Double {
    static var random: Double {
        return Double(arc4random()) / 0xFFFF_FFFF
    }

    static func random(min: Double, max: Double) -> Double {
        return Double.random * (max - min) + min
    }
}
