import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import Logging

/// H.264 hardware encoder using VideoToolbox
final class H264Encoder: @unchecked Sendable {
    static let shared = H264Encoder()
    
    private let logger = Logger(label: "com.virtualmonitor.encoder")
    private let config = AppConfiguration.shared
    
    private var compressionSession: VTCompressionSession?
    private var isEncoding = false
    private let encoderQueue = DispatchQueue(label: "com.virtualmonitor.encoder", qos: .userInteractive)
    
    // Bounded frame queue for backpressure handling
    private var pendingFrameCount = 0
    private let maxPendingFrames: Int
    private let pendingLock = NSLock()
    
    // Encoded frame handler
    var encodedFrameHandler: ((EncodedFrame) -> Void)?
    
    // SPS/PPS data for stream initialization
    private var sps: Data?
    private var pps: Data?
    private var hasParameterSets = false
    
    // Statistics
    private var encodedFrameCount: UInt64 = 0
    private var droppedFrameCount: UInt64 = 0
    private var lastKeyframeTime: Date?
    
    private init() {
        maxPendingFrames = config.maxFrameQueueSize
    }
    
    /// Initialize the encoder
    func initialize() throws {
        guard compressionSession == nil else {
            logger.warning("Encoder already initialized")
            return
        }
        
        logger.info("Initializing H.264 encoder...")
        
        // Encoder specification - prefer hardware
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: config.useHardwareEncoder
        ]
        
        // Create compression session
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(config.streamWidth),
            height: Int32(config.streamHeight),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else {
            throw EncoderError.initializationFailed(status)
        }
        
        compressionSession = session
        
        // Configure encoder for low latency
        try configureSession(session)
        
        // Prepare to encode
        VTCompressionSessionPrepareToEncodeFrames(session)
        
        isEncoding = true
        logger.info("H.264 encoder initialized successfully")
    }
    
    /// Configure compression session for low-latency encoding
    private func configureSession(_ session: VTCompressionSession) throws {
        // Real-time encoding
        try setProperty(session, key: kVTCompressionPropertyKey_RealTime, value: true)
        
        // Profile: High for 4K quality
        try setProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, 
                       value: kVTProfileLevel_H264_High_AutoLevel)
        
        // Bitrate
        try setProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, 
                       value: config.encoderBitrateBps)
        
        // Data rate limits (peak bitrate)
        let dataRateLimits: [Int] = [config.encoderBitrateBps * 2, 1]  // bytes per second, seconds
        try setProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, 
                       value: dataRateLimits as CFArray)
        
        // Frame rate
        try setProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, 
                       value: config.targetFPS)
        
        // Keyframe interval (in frames)
        let keyframeInterval = config.targetFPS * Int(config.keyframeIntervalSeconds)
        try setProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, 
                       value: keyframeInterval)
        try setProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 
                       value: config.keyframeIntervalSeconds)
        
        // Low latency settings
        try setProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: false)
        try setProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0)
        
        // Quality vs speed - favor speed for low latency
        if #available(macOS 13.0, *) {
            try setProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, 
                           value: true)
        }
        
        // Entropy coding - CABAC for efficiency
        try setProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, 
                       value: kVTH264EntropyMode_CABAC)
        
        logger.debug("Encoder configured: \(config.streamWidth)x\(config.streamHeight)@\(config.targetFPS)fps, \(config.encoderBitrateMbps)Mbps")
    }
    
    /// Helper to set compression session properties
    private func setProperty(_ session: VTCompressionSession, key: CFString, value: Any) throws {
        let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        if status != noErr {
            // -12900 is kVTPropertyNotSupportedErr - property not supported by this encoder
            // This is expected for some properties on certain hardware, log at debug level
            if status == -12900 {
                logger.debug("Property \(key) not supported by this encoder (skipping)")
            } else {
                logger.warning("Failed to set property \(key): \(status)")
            }
        }
    }
    
    /// Encode a captured frame
    func encode(sampleBuffer: CMSampleBuffer) {
        guard isEncoding, let session = compressionSession else {
            return
        }
        
        // Check backpressure
        pendingLock.lock()
        if pendingFrameCount >= maxPendingFrames {
            pendingLock.unlock()
            droppedFrameCount += 1
            if droppedFrameCount % 60 == 0 {
                logger.debug("Dropped \(droppedFrameCount) frames due to encoder backpressure")
            }
            return
        }
        pendingFrameCount += 1
        pendingLock.unlock()
        
        // Get pixel buffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            decrementPendingCount()
            return
        }
        
        // Get presentation timestamp
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        
        // Frame properties
        var frameProperties: [CFString: Any] = [:]
        
        // Force keyframe if needed (first frame or periodic)
        let forceKeyframe: Bool
        if !hasParameterSets {
            forceKeyframe = true
        } else if let lastKeyframe = lastKeyframeTime,
                  Date().timeIntervalSince(lastKeyframe) >= config.keyframeIntervalSeconds {
            forceKeyframe = true
        } else {
            forceKeyframe = false
        }
        
        if forceKeyframe {
            frameProperties[kVTEncodeFrameOptionKey_ForceKeyFrame] = true
        }
        
        // Encode asynchronously
        encoderQueue.async { [weak self] in
            self?.performEncode(session: session, pixelBuffer: pixelBuffer, 
                               pts: pts, duration: duration, 
                               frameProperties: frameProperties)
        }
    }
    
    /// Perform the actual encoding
    private func performEncode(session: VTCompressionSession, pixelBuffer: CVPixelBuffer, 
                               pts: CMTime, duration: CMTime, 
                               frameProperties: [CFString: Any]) {
        var infoFlags = VTEncodeInfoFlags()
        
        // Create output handler
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties as CFDictionary,
            infoFlagsOut: &infoFlags
        ) { [weak self] status, flags, sampleBuffer in
            self?.handleEncodedFrame(status: status, flags: flags, sampleBuffer: sampleBuffer)
        }
        
        if status != noErr {
            logger.error("Encode failed with status: \(status)")
            decrementPendingCount()
        }
    }
    
    /// Handle encoded frame output
    private func handleEncodedFrame(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        defer { decrementPendingCount() }
        
        guard status == noErr else {
            logger.error("Encoding error: \(status)")
            return
        }
        
        guard let sampleBuffer = sampleBuffer else {
            return
        }
        
        // Check if this is a keyframe
        let isKeyframe = sampleBuffer.isKeyframe
        
        if isKeyframe {
            lastKeyframeTime = Date()
            
            // Extract SPS/PPS from keyframe
            extractParameterSets(from: sampleBuffer)
        }
        
        // Get the encoded data
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }
        
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, 
                                                  totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        guard status == noErr, let dataPointer = dataPointer else {
            return
        }
        
        let data = Data(bytes: dataPointer, count: length)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        // Convert AVCC to Annex B format for WebRTC
        let annexBData = convertToAnnexB(avccData: data, isKeyframe: isKeyframe)
        
        let encodedFrame = EncodedFrame(
            data: annexBData,
            isKeyframe: isKeyframe,
            timestamp: pts,
            sps: isKeyframe ? sps : nil,
            pps: isKeyframe ? pps : nil
        )
        
        encodedFrameCount += 1
        encodedFrameHandler?(encodedFrame)
    }
    
    /// Extract SPS/PPS from a keyframe's format description
    private func extractParameterSets(from sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }
        
        // Get SPS
        var spsSize: Int = 0
        var spsCount: Int = 0
        var spsPointer: UnsafePointer<UInt8>?
        
        var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription, parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil
        )
        
        if status == noErr, let spsPointer = spsPointer {
            sps = Data(bytes: spsPointer, count: spsSize)
        }
        
        // Get PPS
        var ppsSize: Int = 0
        var ppsPointer: UnsafePointer<UInt8>?
        
        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription, parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
        )
        
        if status == noErr, let ppsPointer = ppsPointer {
            pps = Data(bytes: ppsPointer, count: ppsSize)
        }
        
        hasParameterSets = sps != nil && pps != nil
        
        if hasParameterSets {
            logger.debug("Extracted parameter sets - SPS: \(sps?.count ?? 0) bytes, PPS: \(pps?.count ?? 0) bytes")
        }
    }
    
    /// Convert AVCC format to Annex B format (required for WebRTC)
    private func convertToAnnexB(avccData: Data, isKeyframe: Bool) -> Data {
        var annexBData = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        
        // Add SPS/PPS before keyframes
        if isKeyframe {
            if let sps = sps {
                annexBData.append(contentsOf: startCode)
                annexBData.append(sps)
            }
            if let pps = pps {
                annexBData.append(contentsOf: startCode)
                annexBData.append(pps)
            }
        }
        
        // Parse AVCC NAL units and convert to Annex B
        var offset = 0
        while offset < avccData.count - 4 {
            // AVCC uses 4-byte length prefix
            let lengthData = avccData.subdata(in: offset..<offset+4)
            let length = lengthData.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(as: UInt32.self).bigEndian
            }
            
            offset += 4
            
            guard offset + Int(length) <= avccData.count else {
                break
            }
            
            // Add start code and NAL unit
            annexBData.append(contentsOf: startCode)
            annexBData.append(avccData.subdata(in: offset..<offset+Int(length)))
            
            offset += Int(length)
        }
        
        return annexBData
    }
    
    /// Decrement pending frame count
    private func decrementPendingCount() {
        pendingLock.lock()
        pendingFrameCount = max(0, pendingFrameCount - 1)
        pendingLock.unlock()
    }
    
    /// Force a keyframe on next encode
    func forceKeyframe() {
        hasParameterSets = false
    }
    
    /// Shutdown encoder
    func shutdown() {
        guard isEncoding, let session = compressionSession else { return }
        
        isEncoding = false
        
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        
        compressionSession = nil
        sps = nil
        pps = nil
        hasParameterSets = false
        
        logger.info("Encoder shutdown. Encoded: \(encodedFrameCount), Dropped: \(droppedFrameCount)")
    }
    
    deinit {
        shutdown()
    }
}

// MARK: - Supporting Types

/// Encoded H.264 frame
struct EncodedFrame {
    let data: Data           // Annex B format NAL units
    let isKeyframe: Bool
    let timestamp: CMTime
    let sps: Data?           // Present only on keyframes
    let pps: Data?           // Present only on keyframes
    
    var timestampMs: UInt64 {
        UInt64(CMTimeGetSeconds(timestamp) * 1000)
    }
}

/// Encoder errors
enum EncoderError: Error, LocalizedError {
    case initializationFailed(OSStatus)
    case encodingFailed(OSStatus)
    case notInitialized
    
    var errorDescription: String? {
        switch self {
        case .initializationFailed(let status):
            return "Encoder initialization failed with status: \(status)"
        case .encodingFailed(let status):
            return "Encoding failed with status: \(status)"
        case .notInitialized:
            return "Encoder not initialized"
        }
    }
}

// MARK: - CMSampleBuffer Extension

extension CMSampleBuffer {
    var isKeyframe: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return false
        }
        
        // If kCMSampleAttachmentKey_NotSync is not present or is false, it's a keyframe
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }
}
