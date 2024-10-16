import AVFoundation
import Foundation

class RecorderStreamDelegate: NSObject, AudioRecordingStreamDelegate {
    private var audioEngine: AVAudioEngine?
    private var amplitude: Float = -160.0
    private let bus = 0
    
    func start(config: RecordConfig, recordEventHandler: RecordStreamHandler) throws {
        let audioEngine = AVAudioEngine()
        
#if os(iOS)
        try initAVAudioSession(config: config)
        try initVoiceProcessing(config: config, audioEngine: audioEngine)
#else
        // set input device to the node
        if let deviceId = config.device?.id,
           let inputDeviceId = getAudioDeviceIDFromUID(uid: deviceId) {
            do {
                try audioEngine.inputNode.auAudioUnit.setDeviceID(inputDeviceId)
            } catch {
                throw RecorderError.error(
                    message: "Failed to start recording",
                    details: "Setting input device: \(deviceId) \(error)"
                )
            }
        }
#endif
        
        var srcFormat = audioEngine.inputNode.inputFormat(forBus: 0)
        
        srcFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: srcFormat.sampleRate,
            channels: srcFormat.channelCount,
            interleaved: srcFormat.isInterleaved
        ) ?? srcFormat
        
        let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(config.sampleRate),
            channels: AVAudioChannelCount(config.numChannels),
            interleaved: true
        )
        
        guard let dstFormat = dstFormat else {
            throw RecorderError.error(
                message: "Failed to start recording",
                details: "Format is not supported: \(config.sampleRate)Hz - \(config.numChannels) channels."
            )
        }
        
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw RecorderError.error(
                message: "Failed to start recording",
                details: "Format conversion is not possible."
            )
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        
        audioEngine.inputNode.installTap(onBus: bus, bufferSize: 8960, format: srcFormat) { (buffer, _) -> Void in
            self.stream(
                buffer: buffer,
                dstFormat: dstFormat,
                converter: converter,
                recordEventHandler: recordEventHandler
            )
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        self.audioEngine = audioEngine
    }
    
    func stop(completionHandler: @escaping (String?) -> ()) {
        audioEngine?.inputNode.removeTap(onBus: bus)
        audioEngine?.stop()
        audioEngine = nil
        
        completionHandler(nil)
    }
    
    func pause() {
        audioEngine?.pause()
    }
    
    func resume() throws {
        try audioEngine?.start()
    }
    
    func cancel() throws {
        stop { path in }
    }
    
    func getAmplitude() -> Float {
        return amplitude
    }
    
    private func updateAmplitude(_ samples: [Int16]) {
        var maxSample:Float = -160.0
        
        for sample in samples {
            let curSample = abs(Float(sample))
            if (curSample > maxSample) {
                maxSample = curSample
            }
        }
        
        amplitude = 20 * (log(maxSample / 32767.0) / log(10))
    }
    
    func dispose() {
        stop { path in }
    }
    
    // Little endian
    private func convertInt16toUInt8(_ samples: [Int16]) -> [UInt8] {
        var bytes: [UInt8] = []
        
        for sample in samples {
            bytes.append(UInt8(sample & 0x00ff))
            bytes.append(UInt8(sample >> 8 & 0x00ff))
        }
        
        return bytes
    }
    
    private func stream(
        buffer: AVAudioPCMBuffer,
        dstFormat: AVAudioFormat,
        converter: AVAudioConverter,
        recordEventHandler: RecordStreamHandler
    ) -> Void {
        let inputCallback: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        
        // Determine frame capacity
//        print("buffer famelength \(buffer.frameLength) channel count \(buffer.format.channelCount) dstFormat.channelCount \(dstFormat.channelCount)")
        let channelRatio = Double(dstFormat.channelCount) / Double(buffer.format.channelCount)
        let srRatio = Double(dstFormat.sampleRate) / Double(buffer.format.sampleRate)
        let capacity = UInt32(srRatio * Double(buffer.frameLength))
        
        // Destination buffer
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: capacity) else {
            print("Unable to create output buffer")
            stop { path in }
            return
        }
        
        // Convert input buffer (resample, num channels)
        var error: NSError? = nil
        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputCallback)
        if error != nil {
            print("Conversion Error")
            return
        }
        //        print("buffer format \(buffer.format)dstFormat \(dstFormat) buffer stride \(buffer.stride) converted buffer stride \(convertedBuffer.stride) buffer frameLength \(buffer.frameLength) convertedBuffer frameLength \(convertedBuffer.frameLength)  ")
        
        
        if let channelData = convertedBuffer.int16ChannelData?[0] {
            let numBytes = Int(convertedBuffer.frameLength * convertedBuffer.format.channelCount * 2)
            let bytes = channelData.withMemoryRebound(to: UInt8.self, capacity: numBytes) { ptr in
                Data(buffer:UnsafeBufferPointer(start:ptr, count:numBytes))
            }
            
            if let eventSink = recordEventHandler.eventSink {
                DispatchQueue.main.async {
                    eventSink(FlutterStandardTypedData(bytes: bytes))
                }
            }
        }
    }
    
    // Set up AGC & echo cancel
    private func initVoiceProcessing(config: RecordConfig, audioEngine: AVAudioEngine) throws {
        if #available(iOS 13.0, *) {
            do {
                try audioEngine.inputNode.setVoiceProcessingEnabled(config.echoCancel)
                audioEngine.inputNode.isVoiceProcessingAGCEnabled = config.autoGain
            } catch {
                throw RecorderError.error(
                    message: "Failed to start recording",
                    details: "Echo cancel error: \(error)"
                )
            }
        }
    }
}
