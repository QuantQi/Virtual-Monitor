import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import Logging

/// Main server handling HTTP and WebSocket connections
final class BrowserRelayServer {
    private let logger = Logger(label: "com.virtualmonitor.server")
    private let group: MultiThreadedEventLoopGroup
    private let bootstrap: ServerBootstrap
    private var channel: Channel?
    private let sslContext: NIOSSLContext?
    
    let host: String
    let port: Int
    let sessionManager: SessionManager
    let webRTCManager: WebRTCManager
    let inputInjector: InputInjector
    
    init(host: String, port: Int, sessionManager: SessionManager, webRTCManager: WebRTCManager, inputInjector: InputInjector, sslContext: NIOSSLContext? = nil) async throws {
        self.host = host
        self.port = port
        self.sessionManager = sessionManager
        self.webRTCManager = webRTCManager
        self.inputInjector = inputInjector
        self.sslContext = sslContext
        
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        
        // Create WebSocket upgrader
        let websocketUpgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, head in
                // Only upgrade /ws path, check auth token
                guard head.uri.hasPrefix("/ws") else {
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                
                // Validate auth token if configured
                if let expectedToken = AppConfiguration.shared.authToken {
                    let queryItems = URLComponents(string: head.uri)?.queryItems ?? []
                    let providedToken = queryItems.first(where: { $0.name == "token" })?.value
                    
                    if providedToken != expectedToken {
                        return channel.eventLoop.makeSucceededFuture(nil)
                    }
                }
                
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(
                    WebSocketHandler(
                        sessionManager: sessionManager,
                        webRTCManager: webRTCManager,
                        inputInjector: inputInjector
                    )
                )
            }
        )
        
        self.bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [sslContext] channel in
                let httpHandler = HTTPHandler(
                    sessionManager: sessionManager,
                    webRTCManager: webRTCManager,
                    inputInjector: inputInjector
                )
                
                let config: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [websocketUpgrader],
                    completionHandler: { context in
                        // Remove HTTP handler after successful upgrade
                        context.pipeline.removeHandler(httpHandler, promise: nil)
                    }
                )
                
                // Configure HTTP pipeline (with optional TLS)
                let configureHTTP: EventLoopFuture<Void> = channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: config,
                    withErrorHandling: true
                ).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
                
                // If TLS is enabled, add SSL handler first
                if let sslContext = sslContext {
                    let sslHandler = NIOSSLServerHandler(context: sslContext)
                    return channel.pipeline.addHandler(sslHandler).flatMap {
                        configureHTTP
                    }
                } else {
                    return configureHTTP
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
    }
    
    func run() async throws {
        do {
            channel = try await bootstrap.bind(host: host, port: port).get()
            logger.info("Server bound to \(host):\(port)")
        } catch let error as IOError where error.errnoCode == EADDRINUSE {
            logger.error("Port \(port) is already in use (errno: 48)")
            logger.error("To fix this, either:")
            logger.error("  1) Kill the process using the port: lsof -ti :\(port) | xargs kill -9")
            logger.error("  2) Use a different port: VM_PORT=<port_number> ./VirtualMonitor")
            throw error
        }
        
        // Keep running until channel closes
        try await channel?.closeFuture.get()
    }
    
    func shutdown() async throws {
        try await channel?.close()
        try await group.shutdownGracefully()
    }
}

/// HTTP request handler - handles regular HTTP requests (WebSocket upgrade handled by NIO)
final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    
    private let logger = Logger(label: "com.virtualmonitor.http")
    private let sessionManager: SessionManager
    private let webRTCManager: WebRTCManager
    private let inputInjector: InputInjector
    
    private var requestHead: HTTPRequestHead?
    private var requestBody = ByteBuffer()
    
    init(sessionManager: SessionManager, webRTCManager: WebRTCManager, inputInjector: InputInjector) {
        self.sessionManager = sessionManager
        self.webRTCManager = webRTCManager
        self.inputInjector = inputInjector
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        
        switch part {
        case .head(let head):
            requestHead = head
            requestBody.clear()
            
        case .body(var body):
            requestBody.writeBuffer(&body)
            
        case .end:
            guard let head = requestHead else { return }
            handleRequest(context: context, head: head, body: requestBody)
        }
    }
    
    private func handleRequest(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer) {
        let uri = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        
        logger.debug("Request: \(head.method) \(uri)")
        
        // Handle CORS preflight requests
        if head.method == .OPTIONS {
            serveCORSPreflight(context: context)
            return
        }
        
        // Handle HTTP requests (WebSocket upgrade is handled by NIO automatically)
        switch (head.method, uri) {
        case (.GET, "/"):
            serveStaticFile(context: context, filename: "index.html", contentType: "text/html")
            
        case (.GET, "/client.js"):
            serveStaticFile(context: context, filename: "client.js", contentType: "application/javascript")
            
        case (.GET, "/style.css"):
            serveStaticFile(context: context, filename: "style.css", contentType: "text/css")
            
        case (.GET, "/config"):
            serveConfig(context: context)
            
        case (.GET, "/health"):
            serveHealth(context: context)
            
        case (.GET, "/ws"):
            // If we get here, WebSocket upgrade failed (bad token or not a valid upgrade request)
            serve401(context: context)
            
        default:
            logger.warning("Unhandled request: \(head.method) \(uri)")
            serve404(context: context)
        }
    }
    
    private func serveStaticFile(context: ChannelHandlerContext, filename: String, contentType: String) {
        // Get the resource from the bundle
        if let resourceURL = Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "Resources"),
           let data = try? Data(contentsOf: resourceURL) {
            sendResponse(context: context, status: .ok, contentType: contentType, body: data)
            return
        }
        
        // Try loading from development path
        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent(filename)
        
        if let data = try? Data(contentsOf: devPath) {
            sendResponse(context: context, status: .ok, contentType: contentType, body: data)
            return
        }
        
        serve404(context: context)
    }
    
    private func serveConfig(context: ChannelHandlerContext) {
        let config = AppConfiguration.shared
        let response: [String: Any] = [
            "streamResolution": "\(config.streamWidth)x\(config.streamHeight)",
            "targetFPS": config.targetFPS,
            "width": config.streamWidth,
            "height": config.streamHeight
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            sendResponse(context: context, status: .ok, contentType: "application/json", body: data)
        } else {
            serve500(context: context)
        }
    }
    
    private func serveHealth(context: ChannelHandlerContext) {
        let response: [String: Any] = [
            "status": "ok",
            "activeSession": sessionManager.hasActiveSession,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            sendResponse(context: context, status: .ok, contentType: "application/json", body: data)
        } else {
            serve500(context: context)
        }
    }
    
    private func serve404(context: ChannelHandlerContext) {
        sendResponse(context: context, status: .notFound, contentType: "text/plain", body: Data("Not Found".utf8))
    }
    
    private func serve401(context: ChannelHandlerContext) {
        sendResponse(context: context, status: .unauthorized, contentType: "text/plain", body: Data("Unauthorized".utf8))
    }
    
    private func serve500(context: ChannelHandlerContext) {
        sendResponse(context: context, status: .internalServerError, contentType: "text/plain", body: Data("Internal Server Error".utf8))
    }
    
    private func serveCORSPreflight(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, OPTIONS")
        headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Authorization")
        headers.add(name: "Access-Control-Max-Age", value: "86400")
        headers.add(name: "Content-Length", value: "0")
        
        let head = HTTPResponseHead(version: .http1_1, status: .noContent, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
    
    private func sendResponse(context: ChannelHandlerContext, status: HTTPResponseStatus, contentType: String, body: Data) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(body.count)")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Check for common errors and provide helpful messages
        let errorString = String(describing: error)
        if errorString.contains("invalidMethod") || errorString.contains("invalid http method") {
            logger.warning("Invalid HTTP method - possible HTTPS request to HTTP server or malformed request")
        } else {
            logger.error("HTTP error: \(error)")
        }
        context.close(promise: nil)
    }
}
