import Foundation
import Logging
import NIOSSL

// Configure logging
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = .info
    return handler
}

let logger = Logger(label: "com.virtualmonitor.main")

// Main application
struct VirtualMonitorApp {
    static func run() async throws {
        logger.info("Virtual Monitor starting...")
        
        // Configuration
        let config = AppConfiguration.shared
        
        // Build SSL context if TLS is enabled
        let sslContext: NIOSSLContext?
        if config.tlsEnabled {
            do {
                sslContext = try makeServerSSLContext(from: config)
                logger.info("TLS enabled")
            } catch {
                logger.error("Failed to configure TLS: \(error)")
                throw error
            }
        } else {
            sslContext = nil
        }
        
        // Determine listening port
        let port = config.tlsEnabled ? config.tlsPort : config.serverPort
        let scheme = config.tlsEnabled ? "https" : "http"
        
        logger.info("Server will listen on port \(port)")
        logger.info("Stream resolution: \(config.streamWidth)x\(config.streamHeight)@\(config.targetFPS)fps")
        
        // Check permissions
        await checkPermissions()
        
        // Initialize components
        let sessionManager = SessionManager.shared
        let captureManager = ScreenCaptureManager.shared
        let encoder = H264Encoder.shared
        let webRTCManager = WebRTCManager.shared
        let inputInjector = InputInjector.shared
        
        // Wire up the pipeline
        // Option 1: Send raw frames to WebRTC (let WebRTC handle encoding)
        captureManager.frameHandler = { sampleBuffer in
            webRTCManager.sendFrame(sampleBuffer)
        }
        
        // Option 2: Use our own H.264 encoder (for future custom encoding)
        // captureManager.frameHandler = { sampleBuffer in
        //     encoder.encode(sampleBuffer: sampleBuffer)
        // }
        // encoder.encodedFrameHandler = { encodedFrame in
        //     webRTCManager.sendEncodedFrame(encodedFrame)
        // }
        
        // Initialize encoder (for future use with custom encoding path)
        do {
            try encoder.initialize()
        } catch {
            logger.warning("Failed to initialize H.264 encoder: \(error)")
        }
        
        // Start the server
        let server = try await BrowserRelayServer(
            host: "0.0.0.0",
            port: port,
            sessionManager: sessionManager,
            webRTCManager: webRTCManager,
            inputInjector: inputInjector,
            sslContext: sslContext
        )
        
        logger.info("Binding server to port \(port)...")
        
        // Run the server (this will bind and block until shutdown)
        // Success message is logged by BrowserRelayServer after successful bind
        Task {
            // Wait a moment for bind to complete, then show access URL
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            logger.info("Access the client at: \(scheme)://\(getLocalIPAddress() ?? "localhost"):\(port)/")
        }
        
        try await server.run()
    }
    
    static func checkPermissions() async {
        logger.info("Checking required permissions...")
        
        // Check screen capture permission
        logger.info("Checking Screen Recording permission...")
        let hasScreenPermission = await ScreenCaptureManager.checkPermission()
        if hasScreenPermission {
            logger.info("✅ Screen Recording permission: GRANTED")
        } else {
            logger.error("❌ Screen Recording permission: DENIED")
            logger.warning("   Please enable in System Settings > Privacy & Security > Screen Recording")
            logger.warning("   You may need to restart the app after granting permission")
        }
        
        // Check accessibility permission for input injection
        logger.info("Checking Accessibility permission...")
        let hasAccessibilityPermission = InputInjector.checkPermission()
        if hasAccessibilityPermission {
            logger.info("✅ Accessibility permission: GRANTED")
        } else {
            logger.error("❌ Accessibility permission: DENIED")
            logger.warning("   Please enable in System Settings > Privacy & Security > Accessibility")
            logger.warning("   Input injection (mouse/keyboard) will not work without this permission")
        }
        
        // Summary
        if hasScreenPermission && hasAccessibilityPermission {
            logger.info("All required permissions are granted ✅")
        } else {
            logger.warning("Some permissions are missing - functionality may be limited")
        }
    }
    
    static func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            guard let interface = ptr?.pointee else { continue }
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        return address
    }
}

// Entry point
Task {
    do {
        try await VirtualMonitorApp.run()
    } catch {
        print("Fatal error: \(error)")
        exit(1)
    }
}

// Keep the main thread alive
RunLoop.main.run()
