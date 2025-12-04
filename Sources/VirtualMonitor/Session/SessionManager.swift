import Foundation
import NIO
import Logging

/// Manages client sessions (single active client at a time)
final class SessionManager: @unchecked Sendable {
    static let shared = SessionManager()
    
    private let logger = Logger(label: "com.virtualmonitor.session")
    private let sessionLock = NSLock()
    
    // Current active session
    private var currentSession: ClientSession?
    
    private init() {}
    
    /// Check if there's an active session
    var hasActiveSession: Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return currentSession != nil
    }
    
    /// Get the current session
    var activeSession: ClientSession? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return currentSession
    }
    
    /// Create a new session for a client
    /// Returns nil if a session is already active
    func createSession(channel: Channel) -> ClientSession? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        
        // Check if session already exists
        if let existing = currentSession {
            // Check if the existing session is still valid
            if existing.isActive {
                logger.warning("Rejecting new connection: session already active (id: \(existing.id))")
                return nil
            }
            
            // Existing session is stale, clean it up
            logger.info("Cleaning up stale session: \(existing.id)")
        }
        
        // Create new session
        let session = ClientSession(channel: channel)
        currentSession = session
        
        logger.info("Created new session: \(session.id) from \(channel.remoteAddress?.description ?? "unknown")")
        
        return session
    }
    
    /// End a session
    func endSession(_ session: ClientSession) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        
        guard currentSession?.id == session.id else {
            logger.warning("Attempted to end non-active session: \(session.id)")
            return
        }
        
        session.deactivate()
        currentSession = nil
        
        logger.info("Session ended: \(session.id)")
        
        // Stop capture and encoder when client disconnects
        Task {
            await ScreenCaptureManager.shared.stopCapture()
        }
    }
    
    /// Force end the current session (for emergency stop)
    func forceEndCurrentSession() {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        
        if let session = currentSession {
            session.deactivate()
            session.close()
            currentSession = nil
            logger.warning("Force ended session: \(session.id)")
        }
    }
}

/// Represents a client session
final class ClientSession: @unchecked Sendable {
    let id: String
    let createdAt: Date
    
    private weak var channel: Channel?
    private var _isActive: Bool = true
    private var _controlEnabled: Bool = true
    private let lock = NSLock()
    
    // Message handler for sending messages to client
    var messageHandler: ((SignalingMessage) -> Void)?
    
    init(channel: Channel) {
        self.id = UUID().uuidString
        self.createdAt = Date()
        self.channel = channel
    }
    
    /// Check if session is still active
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isActive && (channel?.isActive ?? false)
    }
    
    /// Check if control (input injection) is enabled
    var controlEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _controlEnabled
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _controlEnabled = newValue
        }
    }
    
    /// Session duration
    var duration: TimeInterval {
        Date().timeIntervalSince(createdAt)
    }
    
    /// Deactivate the session
    func deactivate() {
        lock.lock()
        defer { lock.unlock() }
        _isActive = false
    }
    
    /// Close the underlying connection
    func close() {
        channel?.close(promise: nil)
    }
    
    /// Send a message to the client
    func sendMessage(_ message: SignalingMessage) {
        messageHandler?(message)
    }
}
