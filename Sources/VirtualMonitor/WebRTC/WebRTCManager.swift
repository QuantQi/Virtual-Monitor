import Foundation
import WebRTC
import CoreMedia
import Logging

/// Protocol for WebRTC manager delegate
protocol WebRTCManagerDelegate: AnyObject {
    func webRTCManager(_ manager: WebRTCManager, didGenerateOffer sdp: String)
    func webRTCManager(_ manager: WebRTCManager, didGenerateCandidate candidate: String, sdpMLineIndex: Int32, sdpMid: String?)
    func webRTCManager(_ manager: WebRTCManager, didChangeConnectionState state: String)
}

/// Manages WebRTC peer connection and video streaming
final class WebRTCManager: NSObject, @unchecked Sendable {
    static let shared = WebRTCManager()
    
    private let logger = Logger(label: "com.virtualmonitor.webrtc")
    private let config = AppConfiguration.shared
    
    // WebRTC components
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory,
            decoderFactory: videoDecoderFactory
        )
    }()
    
    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var videoTrack: RTCVideoTrack?
    
    // Custom video capturer for screen capture frames
    private var screenCapturer: ScreenVideoCapturer?
    
    // Delegate
    weak var delegate: WebRTCManagerDelegate?
    
    // State
    private var isConnected = false
    private var pendingCandidates: [RTCIceCandidate] = []
    
    private override init() {
        super.init()
    }
    
    /// Create a new peer connection and generate offer
    func createOffer() {
        logger.info("Creating WebRTC offer...")
        
        // Clean up existing connection
        disconnect()
        
        // Create peer connection
        let rtcConfig = RTCConfiguration()
        rtcConfig.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        ]
        rtcConfig.sdpSemantics = .unifiedPlan
        rtcConfig.continualGatheringPolicy = .gatherContinually
        rtcConfig.bundlePolicy = .maxBundle
        rtcConfig.rtcpMuxPolicy = .require
        
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        
        guard let pc = WebRTCManager.factory.peerConnection(
            with: rtcConfig,
            constraints: constraints,
            delegate: self
        ) else {
            logger.error("Failed to create peer connection")
            return
        }
        
        peerConnection = pc
        
        // Create video track
        setupVideoTrack()
        
        // Create offer
        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveVideo": "false",
                "OfferToReceiveAudio": "false"
            ],
            optionalConstraints: nil
        )
        
        pc.offer(for: offerConstraints) { [weak self] sdp, error in
            guard let self = self, let sdp = sdp else {
                self?.logger.error("Failed to create offer: \(error?.localizedDescription ?? "unknown")")
                return
            }
            
            // Modify SDP to prefer H.264
            let modifiedSDP = self.preferH264(sdp: sdp.sdp)
            let modifiedDescription = RTCSessionDescription(type: .offer, sdp: modifiedSDP)
            
            pc.setLocalDescription(modifiedDescription) { error in
                if let error = error {
                    self.logger.error("Failed to set local description: \(error)")
                    return
                }
                
                self.logger.info("Offer created successfully")
                self.delegate?.webRTCManager(self, didGenerateOffer: modifiedSDP)
            }
        }
    }
    
    /// Set up video source and track
    private func setupVideoTrack() {
        guard let pc = peerConnection else { 
            logger.error("No peer connection for video track setup")
            return 
        }
        
        logger.info("Setting up video track...")
        
        // Create video source
        videoSource = WebRTCManager.factory.videoSource()
        logger.debug("Video source created")
        
        // Create screen capturer that feeds frames to the video source
        screenCapturer = ScreenVideoCapturer(source: videoSource!)
        screenCapturer?.startCapture()
        logger.debug("Screen capturer created and started")
        
        // Create video track
        videoTrack = WebRTCManager.factory.videoTrack(with: videoSource!, trackId: "video0")
        videoTrack?.isEnabled = true
        logger.debug("Video track created: \(videoTrack?.trackId ?? "nil")")
        
        // Add track to peer connection
        let streamId = "stream0"
        pc.add(videoTrack!, streamIds: [streamId])
        
        // Configure video parameters
        if let sender = pc.senders.first(where: { $0.track?.kind == "video" }) {
            let parameters = sender.parameters
            
            // Configure encoding parameters for H.264 at high bitrate
            for encoding in parameters.encodings {
                encoding.maxBitrateBps = NSNumber(value: config.webRTCMaxBitrateBps)
                encoding.minBitrateBps = NSNumber(value: config.webRTCMinBitrateBps)
                encoding.maxFramerate = NSNumber(value: config.targetFPS)
                encoding.isActive = true
            }
            
            sender.parameters = parameters
        }
        
        logger.debug("Video track set up with screen capturer")
    }
    
    /// Handle answer SDP from client
    func handleAnswer(sdp: String) {
        guard let pc = peerConnection else {
            logger.error("No peer connection when handling answer")
            return
        }
        
        let answerDescription = RTCSessionDescription(type: .answer, sdp: sdp)
        
        pc.setRemoteDescription(answerDescription) { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to set remote description: \(error)")
                return
            }
            
            self?.logger.info("Answer processed successfully")
            
            // Add any pending ICE candidates
            self?.processPendingCandidates()
        }
    }
    
    /// Handle remote ICE candidate
    func handleRemoteCandidate(candidate: String, sdpMLineIndex: Int32, sdpMid: String?) {
        let iceCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        
        guard let pc = peerConnection else {
            pendingCandidates.append(iceCandidate)
            return
        }
        
        if pc.remoteDescription != nil {
            pc.add(iceCandidate) { [weak self] error in
                if let error = error {
                    self?.logger.warning("Failed to add ICE candidate: \(error)")
                }
            }
        } else {
            pendingCandidates.append(iceCandidate)
        }
    }
    
    /// Process pending ICE candidates
    private func processPendingCandidates() {
        guard let pc = peerConnection else { return }
        
        for candidate in pendingCandidates {
            pc.add(candidate) { [weak self] error in
                if let error = error {
                    self?.logger.warning("Failed to add pending ICE candidate: \(error)")
                }
            }
        }
        pendingCandidates.removeAll()
    }
    
    /// Send encoded H.264 frame - not used, we send raw frames instead
    func sendEncodedFrame(_ frame: EncodedFrame) {
        // WebRTC handles encoding internally via the video track
        // This method is kept for compatibility but not used
    }
    
    /// Send a raw CMSampleBuffer frame to WebRTC
    func sendFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let capturer = screenCapturer else {
            // This can happen before WebRTC connection is established
            return
        }
        capturer.captureFrame(sampleBuffer)
    }
    
    /// Check if the capturer is ready to receive frames
    var isReadyForFrames: Bool {
        return screenCapturer != nil && peerConnection != nil
    }
    
    /// Modify SDP to prefer H.264 codec
    private func preferH264(sdp: String) -> String {
        var lines = sdp.components(separatedBy: "\r\n")
        var videoMLineIndex: Int?
        var h264PayloadTypes: [String] = []
        
        // Find video m-line and H.264 payload types
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("m=video") {
                videoMLineIndex = index
            }
            
            // Look for H.264 rtpmap entries
            if line.contains("H264") || line.contains("h264") {
                if let match = line.range(of: "a=rtpmap:(\\d+)", options: .regularExpression) {
                    let payloadStart = line.index(match.lowerBound, offsetBy: 10)
                    let payloadEnd = line[payloadStart...].firstIndex(of: " ") ?? line.endIndex
                    let payload = String(line[payloadStart..<payloadEnd])
                    h264PayloadTypes.append(payload)
                }
            }
        }
        
        // Reorder codecs to prefer H.264
        if let mLineIndex = videoMLineIndex, !h264PayloadTypes.isEmpty {
            let mLine = lines[mLineIndex]
            let parts = mLine.components(separatedBy: " ")
            
            if parts.count > 3 {
                var payloads = Array(parts[3...])
                
                // Move H.264 payloads to front
                for h264 in h264PayloadTypes.reversed() {
                    if let idx = payloads.firstIndex(of: h264) {
                        payloads.remove(at: idx)
                        payloads.insert(h264, at: 0)
                    }
                }
                
                let newMLine = parts[0..<3].joined(separator: " ") + " " + payloads.joined(separator: " ")
                lines[mLineIndex] = newMLine
            }
        }
        
        return lines.joined(separator: "\r\n")
    }
    
    /// Disconnect and clean up
    func disconnect() {
        isConnected = false
        
        screenCapturer?.stopCapture()
        screenCapturer = nil
        
        videoTrack?.isEnabled = false
        videoTrack = nil
        videoSource = nil
        
        peerConnection?.close()
        peerConnection = nil
        
        pendingCandidates.removeAll()
        
        logger.info("WebRTC disconnected")
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        logger.debug("Signaling state: \(stateChanged.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        logger.debug("Stream added: \(stream.streamId)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        logger.debug("Stream removed: \(stream.streamId)")
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        logger.debug("Negotiation needed")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let stateString: String
        switch newState {
        case .new: stateString = "new"
        case .checking: stateString = "checking"
        case .connected: stateString = "connected"
        case .completed: stateString = "completed"
        case .failed: stateString = "failed"
        case .disconnected: stateString = "disconnected"
        case .closed: stateString = "closed"
        case .count: stateString = "count"
        @unknown default: stateString = "unknown"
        }
        
        logger.info("ICE connection state: \(stateString)")
        
        isConnected = (newState == .connected || newState == .completed)
        delegate?.webRTCManager(self, didChangeConnectionState: stateString)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        let stateString: String
        switch newState {
        case .new: stateString = "new"
        case .gathering: stateString = "gathering"
        case .complete: stateString = "complete"
        @unknown default: stateString = "unknown"
        }
        logger.debug("ICE gathering state: \(stateString)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        logger.debug("Generated ICE candidate")
        delegate?.webRTCManager(self, didGenerateCandidate: candidate.sdp, 
                               sdpMLineIndex: candidate.sdpMLineIndex, 
                               sdpMid: candidate.sdpMid)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        logger.debug("Removed \(candidates.count) ICE candidates")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        logger.debug("Data channel opened: \(dataChannel.label)")
    }
}
