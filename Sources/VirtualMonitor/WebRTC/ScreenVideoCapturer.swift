import Foundation
import WebRTC
import CoreVideo
import CoreMedia
import Logging

/// Custom video capturer that feeds captured frames to WebRTC
final class ScreenVideoCapturer: RTCVideoCapturer {
    private let logger = Logger(label: "com.virtualmonitor.videocapturer")
    private let config = AppConfiguration.shared
    
    private weak var videoSource: RTCVideoSource?
    private var isCapturing = false
    
    private var frameCount: UInt64 = 0
    private var lastStatsTime = Date()
    
    init(source: RTCVideoSource) {
        self.videoSource = source
        super.init(delegate: source)
    }
    
    /// Start the capturer
    func startCapture() {
        isCapturing = true
        frameCount = 0
        lastStatsTime = Date()
        logger.info("Screen video capturer started")
    }
    
    /// Stop the capturer
    func stopCapture() {
        isCapturing = false
        logger.info("Screen video capturer stopped (frames: \(frameCount))")
    }
    
    /// Feed a captured CMSampleBuffer into WebRTC
    func captureFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isCapturing else {
            logger.trace("Not capturing, ignoring frame")
            return
        }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logger.warning("Frame has no pixel buffer")
            return
        }
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        capturePixelBuffer(pixelBuffer, timestamp: timestamp)
    }
    
    /// Feed a CVPixelBuffer into WebRTC
    func capturePixelBuffer(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard isCapturing else { return }
        
        // Create RTCVideoFrame
        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let timestampNs = Int64(CMTimeGetSeconds(timestamp) * Double(NSEC_PER_SEC))
        
        let videoFrame = RTCVideoFrame(
            buffer: rtcPixelBuffer,
            rotation: ._0,
            timeStampNs: timestampNs
        )
        
        // Send to WebRTC video source
        guard let videoDelegate = delegate else {
            logger.warning("No delegate set for video capturer")
            return
        }
        
        videoDelegate.capturer(self, didCapture: videoFrame)
        
        // Update stats
        frameCount += 1
        let now = Date()
        if now.timeIntervalSince(lastStatsTime) >= 5.0 {
            let fps = Double(frameCount) / now.timeIntervalSince(lastStatsTime)
            logger.info("Video capturer: \(frameCount) frames, \(String(format: "%.1f", fps)) fps sent to WebRTC")
            frameCount = 0
            lastStatsTime = now
        }
    }
}

/// Adapter to bridge ScreenCaptureManager with WebRTC
final class WebRTCCaptureAdapter {
    private let logger = Logger(label: "com.virtualmonitor.captureradapter")
    private let capturer: ScreenVideoCapturer
    
    init(capturer: ScreenVideoCapturer) {
        self.capturer = capturer
    }
    
    /// Handle a captured sample buffer
    func handleCapturedFrame(_ sampleBuffer: CMSampleBuffer) {
        capturer.captureFrame(sampleBuffer)
    }
}
