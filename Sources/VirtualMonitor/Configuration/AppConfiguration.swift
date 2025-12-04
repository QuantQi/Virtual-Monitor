import Foundation

/// Application-wide configuration
final class AppConfiguration {
    static let shared = AppConfiguration()
    
    // Server settings
    let serverPort: Int
    let authToken: String?
    
    // Stream settings - fixed 4K@60
    let streamWidth: Int = 3840
    let streamHeight: Int = 2160
    let targetFPS: Int = 60
    
    // Encoder settings
    let encoderBitrateMbps: Int
    let keyframeIntervalSeconds: Double
    let useHardwareEncoder: Bool
    
    // WebRTC settings
    let webRTCMinBitrateBps: Int
    let webRTCMaxBitrateBps: Int
    let webRTCStartBitrateBps: Int
    
    // Queue settings
    let maxFrameQueueSize: Int
    let dropFramesOnBackpressure: Bool
    
    // Input settings
    let maxInputEventsPerSecond: Int
    let enableKeyboardInjection: Bool
    let enableMouseInjection: Bool
    
    private init() {
        // Load from environment or use defaults
        self.serverPort = Int(ProcessInfo.processInfo.environment["VM_PORT"] ?? "") ?? 8080
        self.authToken = ProcessInfo.processInfo.environment["VM_AUTH_TOKEN"]
        
        // Encoder: 25 Mbps default for LAN, good quality at 4K60
        self.encoderBitrateMbps = Int(ProcessInfo.processInfo.environment["VM_BITRATE_MBPS"] ?? "") ?? 25
        self.keyframeIntervalSeconds = 1.0  // Keyframe every second for low latency
        self.useHardwareEncoder = true
        
        // WebRTC bitrate range
        self.webRTCMinBitrateBps = 5_000_000     // 5 Mbps min
        self.webRTCMaxBitrateBps = 40_000_000    // 40 Mbps max
        self.webRTCStartBitrateBps = 25_000_000  // 25 Mbps start
        
        // Frame queue - small to minimize latency
        self.maxFrameQueueSize = 3
        self.dropFramesOnBackpressure = true
        
        // Input injection limits
        self.maxInputEventsPerSecond = 120
        self.enableKeyboardInjection = true
        self.enableMouseInjection = true
    }
    
    var encoderBitrateBps: Int {
        return encoderBitrateMbps * 1_000_000
    }
}
