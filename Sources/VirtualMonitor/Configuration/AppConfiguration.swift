import Foundation

/// Application-wide configuration
final class AppConfiguration {
    static let shared = AppConfiguration()
    
    // Server settings
    let serverPort: Int
    let authToken: String?
    
    // TLS settings
    let tlsEnabled: Bool
    let tlsCertPath: String?
    let tlsKeyPath: String?
    let tlsPort: Int
    
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
        let env = ProcessInfo.processInfo.environment
        
        // Load from environment or use defaults
        self.serverPort = Int(env["VM_PORT"] ?? "") ?? 8080
        self.authToken = env["VM_AUTH_TOKEN"]
        
        // TLS configuration
        self.tlsEnabled = (env["VM_TLS_ENABLED"] ?? "").lowercased() == "true"
        self.tlsCertPath = env["VM_TLS_CERT_PATH"]
        self.tlsKeyPath = env["VM_TLS_KEY_PATH"]
        self.tlsPort = Int(env["VM_TLS_PORT"] ?? "") ?? self.serverPort
        
        // Encoder: 25 Mbps default for LAN, good quality at 4K60
        self.encoderBitrateMbps = Int(env["VM_BITRATE_MBPS"] ?? "") ?? 25
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
