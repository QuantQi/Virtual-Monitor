import Foundation
import NIO
import NIOWebSocket
import Logging

/// Handles WebSocket connections for signaling and input control
final class WebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    
    private let logger = Logger(label: "com.virtualmonitor.websocket")
    private let sessionManager: SessionManager
    private let webRTCManager: WebRTCManager
    private let inputInjector: InputInjector
    
    private var session: ClientSession?
    private weak var channel: Channel?
    
    // Buffer for fragmented frames
    private var frameBuffer = ByteBuffer()
    private var awaitingContinuation = false
    
    init(sessionManager: SessionManager, webRTCManager: WebRTCManager, inputInjector: InputInjector) {
        self.sessionManager = sessionManager
        self.webRTCManager = webRTCManager
        self.inputInjector = inputInjector
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
        logger.info("WebSocket connection established")
        
        // Try to create a new session
        if let newSession = sessionManager.createSession(channel: context.channel) {
            session = newSession
            newSession.messageHandler = { [weak self] message in
                self?.sendMessage(message, context: context)
            }
            
            // Set up WebRTC delegate
            webRTCManager.delegate = self
            
            // Send ready acknowledgment
            sendJSON([
                "type": "server_ready",
                "sessionId": newSession.id,
                "config": [
                    "width": AppConfiguration.shared.streamWidth,
                    "height": AppConfiguration.shared.streamHeight,
                    "fps": AppConfiguration.shared.targetFPS
                ]
            ], context: context)
            
        } else {
            // Session already active, reject
            logger.warning("Rejecting connection: session already active")
            sendJSON([
                "type": "error",
                "message": "Another client is already connected"
            ], context: context)
            
            // Close after sending rejection
            context.eventLoop.scheduleTask(in: .milliseconds(100)) {
                context.close(promise: nil)
            }
        }
    }
    
    func handlerRemoved(context: ChannelHandlerContext) {
        logger.info("WebSocket connection closed")
        
        if let session = session {
            sessionManager.endSession(session)
            webRTCManager.disconnect()
            
            // Stop screen capture when client disconnects
            Task {
                await ScreenCaptureManager.shared.stopCapture()
            }
        }
        session = nil
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        
        switch frame.opcode {
        case .text:
            // Handle fragmented frames
            if !frame.fin {
                var unmaskedData = frame.unmaskedData
                if let bytes = unmaskedData.readBytes(length: unmaskedData.readableBytes) {
                    frameBuffer.writeBytes(bytes)
                }
                awaitingContinuation = true
                return
            }
            handleTextMessage(context: context, frame: frame)
            
        case .continuation:
            var unmaskedData = frame.unmaskedData
            if let bytes = unmaskedData.readBytes(length: unmaskedData.readableBytes) {
                frameBuffer.writeBytes(bytes)
            }
            if frame.fin && awaitingContinuation {
                // Complete message
                awaitingContinuation = false
                handleBufferedMessage(context: context)
            }
            
        case .binary:
            handleBinaryMessage(context: context, frame: frame)
            
        case .ping:
            handlePing(context: context, frame: frame)
            
        case .pong:
            break // Ignore pong
            
        case .connectionClose:
            handleClose(context: context, frame: frame)
            
        default:
            break
        }
    }
    
    private func handleBufferedMessage(context: ChannelHandlerContext) {
        guard let text = frameBuffer.readString(length: frameBuffer.readableBytes) else {
            logger.warning("Failed to read buffered WebSocket frame")
            frameBuffer.clear()
            return
        }
        frameBuffer.clear()
        processJSONMessage(text: text, context: context)
    }
    
    private func handleTextMessage(context: ChannelHandlerContext, frame: WebSocketFrame) {
        var data = frame.unmaskedData
        guard let text = data.readString(length: data.readableBytes) else {
            logger.warning("Failed to read WebSocket text frame")
            return
        }
        
        processJSONMessage(text: text, context: context)
    }
    
    private func processJSONMessage(text: String, context: ChannelHandlerContext) {
        logger.debug("Received raw text: \(text)")
        
        guard let jsonData = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let typeString = json["type"] as? String else {
            logger.warning("Invalid JSON message received: '\(text)'")
            return
        }
        
        logger.info("Received message: \(typeString)")
        
        // Route message based on type
        switch typeString {
        // Signaling messages
        case "client_ready":
            handleClientReady(context: context)
            
        case "webrtc_answer":
            if let sdp = json["sdp"] as? String {
                webRTCManager.handleAnswer(sdp: sdp)
            }
            
        case "ice_candidate":
            if let candidate = json["candidate"] as? String,
               let sdpMLineIndex = json["sdpMLineIndex"] as? Int32,
               let sdpMid = json["sdpMid"] as? String {
                webRTCManager.handleRemoteCandidate(candidate: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
            }
            
        // Input control messages
        case "mouse_move":
            handleMouseMove(json: json)
            
        case "mouse_button":
            handleMouseButton(json: json)
            
        case "mouse_wheel":
            handleMouseWheel(json: json)
            
        case "key":
            handleKey(json: json)
            
        // Session control
        case "stop_control":
            session?.controlEnabled = false
            logger.info("Input control disabled by client request")
            
        case "start_control":
            session?.controlEnabled = true
            logger.info("Input control enabled by client request")
            
        default:
            logger.warning("Unknown message type: \(typeString)")
        }
    }
    
    private func handleBinaryMessage(context: ChannelHandlerContext, frame: WebSocketFrame) {
        // Binary messages not used currently
        logger.debug("Received binary message, ignoring")
    }
    
    private func handlePing(context: ChannelHandlerContext, frame: WebSocketFrame) {
        let frameData = frame.data
        let pongFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
        context.writeAndFlush(wrapOutboundOut(pongFrame), promise: nil)
    }
    
    private func handleClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
        let data = frame.data
        let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        context.writeAndFlush(wrapOutboundOut(closeFrame)).whenComplete { _ in
            context.close(promise: nil)
        }
    }
    
    // MARK: - Client Ready Handler
    
    private func handleClientReady(context: ChannelHandlerContext) {
        logger.info("Client ready, initiating WebRTC connection")
        
        // Start screen capture and create WebRTC offer
        Task {
            do {
                // First create the WebRTC offer (which sets up the video track and capturer)
                // This must be done first so that when capture starts, there's a destination for frames
                logger.info("Creating WebRTC offer...")
                webRTCManager.createOffer()
                
                // Wait a moment for the video track to be set up
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                
                // Now start screen capture
                logger.info("Starting screen capture...")
                try await ScreenCaptureManager.shared.startCapture()
                logger.info("Screen capture started successfully")
                
            } catch {
                logger.error("Failed to start capture: \(error)")
                let errorMessage = SignalingMessage(type: .error, payload: [
                    "message": "Failed to start screen capture: \(error.localizedDescription)"
                ])
                sendMessage(errorMessage, context: context)
            }
        }
    }
    
    // MARK: - Input Handlers
    
    private func handleMouseMove(json: [String: Any]) {
        guard session?.controlEnabled == true,
              let xNorm = json["xNorm"] as? Double,
              let yNorm = json["yNorm"] as? Double else { return }
        
        inputInjector.injectMouseMove(xNorm: xNorm, yNorm: yNorm)
    }
    
    private func handleMouseButton(json: [String: Any]) {
        guard session?.controlEnabled == true,
              let button = json["button"] as? Int,
              let down = json["down"] as? Bool,
              let xNorm = json["xNorm"] as? Double,
              let yNorm = json["yNorm"] as? Double else { return }
        
        inputInjector.injectMouseButton(button: button, down: down, xNorm: xNorm, yNorm: yNorm)
    }
    
    private func handleMouseWheel(json: [String: Any]) {
        guard session?.controlEnabled == true,
              let deltaX = json["deltaX"] as? Double,
              let deltaY = json["deltaY"] as? Double else { return }
        
        inputInjector.injectMouseWheel(deltaX: deltaX, deltaY: deltaY)
    }
    
    private func handleKey(json: [String: Any]) {
        guard session?.controlEnabled == true,
              let keyCode = json["keyCode"] as? String,
              let down = json["down"] as? Bool else { return }
        
        let modifiers = json["modifiers"] as? [String: Bool] ?? [:]
        inputInjector.injectKey(keyCode: keyCode, down: down, modifiers: modifiers)
    }
    
    // MARK: - Message Sending
    
    private func sendMessage(_ message: SignalingMessage, context: ChannelHandlerContext) {
        guard let jsonData = try? JSONEncoder().encode(message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.error("Failed to encode message")
            return
        }
        
        var buffer = context.channel.allocator.buffer(capacity: jsonString.utf8.count)
        buffer.writeString(jsonString)
        
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
    }
    
    private func sendJSON(_ json: [String: Any], context: ChannelHandlerContext) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.error("Failed to serialize JSON")
            return
        }
        
        var buffer = context.channel.allocator.buffer(capacity: jsonString.utf8.count)
        buffer.writeString(jsonString)
        
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
    }
    
    func sendJSON(_ json: [String: Any]) {
        guard let channel = channel,
              let jsonData = try? JSONSerialization.data(withJSONObject: json),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        
        var buffer = channel.allocator.buffer(capacity: jsonString.utf8.count)
        buffer.writeString(jsonString)
        
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        channel.writeAndFlush(frame, promise: nil)
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("WebSocket error: \(error)")
        context.close(promise: nil)
    }
}

// MARK: - WebRTC Delegate

extension WebSocketHandler: WebRTCManagerDelegate {
    func webRTCManager(_ manager: WebRTCManager, didGenerateOffer sdp: String) {
        sendJSON([
            "type": "webrtc_offer",
            "sdp": sdp
        ])
    }
    
    func webRTCManager(_ manager: WebRTCManager, didGenerateCandidate candidate: String, sdpMLineIndex: Int32, sdpMid: String?) {
        sendJSON([
            "type": "ice_candidate",
            "candidate": candidate,
            "sdpMLineIndex": sdpMLineIndex,
            "sdpMid": sdpMid ?? ""
        ])
    }
    
    func webRTCManager(_ manager: WebRTCManager, didChangeConnectionState state: String) {
        sendJSON([
            "type": "connection_state",
            "state": state
        ])
        
        if state == "connected" {
            logger.info("WebRTC connection established")
        } else if state == "disconnected" || state == "failed" {
            logger.warning("WebRTC connection \(state)")
        }
    }
}
