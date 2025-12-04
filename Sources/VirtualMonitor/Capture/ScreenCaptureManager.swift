import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage
import Logging

/// Manages screen capture using ScreenCaptureKit
final class ScreenCaptureManager: NSObject, @unchecked Sendable {
    static let shared = ScreenCaptureManager()
    
    private let logger = Logger(label: "com.virtualmonitor.capture")
    private let config = AppConfiguration.shared
    
    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private var isCapturing = false
    
    // Frame handler - called for each captured frame
    var frameHandler: ((CMSampleBuffer) -> Void)?
    
    // Scaling context for GPU-accelerated scaling
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .highQualityDownsample: true
    ])
    
    // Frame statistics
    private var frameCount: UInt64 = 0
    private var lastStatsTime: Date = Date()
    private var effectiveFPS: Double = 0
    
    private override init() {
        super.init()
    }
    
    /// Check if screen recording permission is granted
    static func checkPermission() async -> Bool {
        do {
            // This will prompt for permission if not granted
            _ = try await SCShareableContent.current
            return true
        } catch {
            return false
        }
    }
    
    /// Start screen capture at 4K@60fps
    func startCapture(displayID: CGDirectDisplayID? = nil) async throws {
        guard !isCapturing else {
            logger.warning("Capture already running")
            return
        }
        
        logger.info("Starting screen capture...")
        
        // Get available content
        let content = try await SCShareableContent.current
        
        // Find the display to capture
        let display: SCDisplay
        if let targetID = displayID,
           let targetDisplay = content.displays.first(where: { $0.displayID == targetID }) {
            display = targetDisplay
        } else if let mainDisplay = content.displays.first {
            display = mainDisplay
        } else {
            throw CaptureError.noDisplayAvailable
        }
        
        logger.info("Capturing display: \(display.displayID) (\(display.width)x\(display.height))")
        
        // Create content filter for the display
        let filter = SCContentFilter(display: display, excludingWindows: [])
        
        // Configure stream for 4K@60fps output
        let streamConfig = SCStreamConfiguration()
        
        // Output resolution - always 4K
        streamConfig.width = config.streamWidth
        streamConfig.height = config.streamHeight
        
        // Frame rate - 60fps
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.targetFPS))
        
        // Pixel format - use BGRA for compatibility with VideoToolbox
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        
        // Quality settings
        streamConfig.showsCursor = true
        streamConfig.capturesAudio = false  // Video only for now
        
        // Queue depth - small for low latency
        streamConfig.queueDepth = config.maxFrameQueueSize
        
        // Color settings
        streamConfig.colorSpaceName = CGColorSpace.sRGB
        
        // Scaling - let ScreenCaptureKit handle it with high quality
        streamConfig.scalesToFit = true
        
        // Create the stream
        stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        
        // Create and add output handler
        streamOutput = CaptureStreamOutput { [weak self] sampleBuffer in
            self?.handleCapturedFrame(sampleBuffer)
        }
        
        try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        
        // Start capturing
        try await stream?.startCapture()
        
        isCapturing = true
        lastStatsTime = Date()
        frameCount = 0
        
        logger.info("Screen capture started at \(config.streamWidth)x\(config.streamHeight)@\(config.targetFPS)fps")
    }
    
    /// Stop screen capture
    func stopCapture() async {
        guard isCapturing else { return }
        
        logger.info("Stopping screen capture...")
        
        do {
            try await stream?.stopCapture()
        } catch {
            logger.error("Error stopping capture: \(error)")
        }
        
        stream = nil
        streamOutput = nil
        isCapturing = false
        
        logger.info("Screen capture stopped")
    }
    
    /// Handle a captured frame
    private func handleCapturedFrame(_ sampleBuffer: CMSampleBuffer) {
        // Update statistics
        frameCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastStatsTime)
        
        if elapsed >= 1.0 {
            effectiveFPS = Double(frameCount) / elapsed
            logger.info("Screen capture: \(frameCount) frames in \(String(format: "%.1f", elapsed))s = \(String(format: "%.1f", effectiveFPS)) fps")
            frameCount = 0
            lastStatsTime = now
            
            if effectiveFPS < Double(config.targetFPS) * 0.9 {
                logger.debug("Effective FPS: \(String(format: "%.1f", effectiveFPS))")
            }
        }
        
        // Validate the frame
        guard let imageBuffer = sampleBuffer.imageBuffer else {
            logger.warning("Frame has no image buffer")
            return
        }
        
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        // If resolution doesn't match, we may need to scale
        // (ScreenCaptureKit should handle this, but double-check)
        if width != config.streamWidth || height != config.streamHeight {
            logger.debug("Frame size mismatch: \(width)x\(height), expected \(config.streamWidth)x\(config.streamHeight)")
            // For now, still pass it through - encoder will handle it
        }
        
        // Pass to frame handler (encoder)
        if let handler = frameHandler {
            handler(sampleBuffer)
        } else {
            if frameCount == 1 {
                logger.warning("No frame handler set - frames are being dropped!")
            }
        }
    }
    
    /// Get current capture statistics
    var statistics: CaptureStatistics {
        CaptureStatistics(
            isCapturing: isCapturing,
            effectiveFPS: effectiveFPS,
            targetFPS: config.targetFPS,
            resolution: "\(config.streamWidth)x\(config.streamHeight)"
        )
    }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Stream stopped with error: \(error)")
        isCapturing = false
        
        // Attempt to restart capture after a delay
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            if !isCapturing {
                logger.info("Attempting to restart capture...")
                try? await startCapture()
            }
        }
    }
}

// MARK: - Stream Output Handler

private final class CaptureStreamOutput: NSObject, SCStreamOutput {
    private let handler: (CMSampleBuffer) -> Void
    
    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
        super.init()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        handler(sampleBuffer)
    }
}

// MARK: - Supporting Types

enum CaptureError: Error, LocalizedError {
    case noDisplayAvailable
    case captureNotRunning
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display available for capture"
        case .captureNotRunning:
            return "Screen capture is not running"
        case .permissionDenied:
            return "Screen recording permission denied"
        }
    }
}

struct CaptureStatistics {
    let isCapturing: Bool
    let effectiveFPS: Double
    let targetFPS: Int
    let resolution: String
}
