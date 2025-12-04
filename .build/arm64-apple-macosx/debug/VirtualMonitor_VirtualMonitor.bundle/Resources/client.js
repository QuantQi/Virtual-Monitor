/**
 * Virtual Monitor Client
 * Handles WebRTC connection, video display, and input capture
 */

class VirtualMonitorClient {
    constructor() {
        // Configuration (will be updated from server)
        this.config = {
            width: 3840,
            height: 2160,
            fps: 60
        };
        
        // WebSocket connection
        this.ws = null;
        this.wsReconnectDelay = 1000;
        this.wsMaxReconnectDelay = 30000;
        
        // WebRTC
        this.pc = null;
        this.remoteStream = null;
        
        // State
        this.isConnected = false;
        this.controlEnabled = true;
        this.isFullscreen = false;
        
        // Input throttling
        this.lastMouseMoveTime = 0;
        this.mouseMoveThrottleMs = 1000 / 120; // 120Hz max
        this.pendingMouseMove = null;
        this.mouseThrottleTimer = null;
        
        // Modifier key state
        this.modifiers = {
            shift: false,
            ctrl: false,
            alt: false,
            meta: false
        };
        
        // DOM elements
        this.elements = {
            video: document.getElementById('remote-video'),
            overlay: document.getElementById('input-overlay'),
            connectionOverlay: document.getElementById('connection-overlay'),
            connectionMessage: document.getElementById('connection-message'),
            statusIndicator: document.getElementById('status-indicator'),
            statusText: document.getElementById('status-text'),
            resolution: document.getElementById('resolution'),
            fps: document.getElementById('fps'),
            latency: document.getElementById('latency'),
            fullscreenBtn: document.getElementById('fullscreen-btn'),
            controlToggle: document.getElementById('control-toggle')
        };
        
        // Stats
        this.stats = {
            framesReceived: 0,
            lastStatsTime: Date.now(),
            fps: 0
        };
        
        this.init();
    }
    
    init() {
        this.setupEventListeners();
        this.connectWebSocket();
        this.startStatsUpdater();
    }
    
    // ==================== WebSocket ====================
    
    connectWebSocket() {
        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        const url = `${protocol}//${window.location.host}/ws`;
        
        // Include auth token if present in URL
        const urlParams = new URLSearchParams(window.location.search);
        const token = urlParams.get('token');
        const wsUrl = token ? `${url}?token=${token}` : url;
        
        this.updateStatus('connecting', 'Connecting...');
        
        try {
            this.ws = new WebSocket(wsUrl);
            
            this.ws.onopen = () => this.onWebSocketOpen();
            this.ws.onclose = (e) => this.onWebSocketClose(e);
            this.ws.onerror = (e) => this.onWebSocketError(e);
            this.ws.onmessage = (e) => this.onWebSocketMessage(e);
        } catch (error) {
            console.error('WebSocket connection failed:', error);
            this.scheduleReconnect();
        }
    }
    
    onWebSocketOpen() {
        console.log('WebSocket connected');
        this.wsReconnectDelay = 1000; // Reset reconnect delay
        
        // Send client ready message
        this.sendMessage({ type: 'client_ready' });
    }
    
    onWebSocketClose(event) {
        console.log('WebSocket closed:', event.code, event.reason);
        this.isConnected = false;
        this.updateStatus('disconnected', 'Disconnected');
        this.showConnectionOverlay('Connection lost. Reconnecting...');
        
        // Close peer connection
        if (this.pc) {
            this.pc.close();
            this.pc = null;
        }
        
        this.scheduleReconnect();
    }
    
    onWebSocketError(error) {
        console.error('WebSocket error:', error);
    }
    
    onWebSocketMessage(event) {
        try {
            const message = JSON.parse(event.data);
            this.handleMessage(message);
        } catch (error) {
            console.error('Failed to parse message:', error);
        }
    }
    
    scheduleReconnect() {
        setTimeout(() => {
            this.wsReconnectDelay = Math.min(this.wsReconnectDelay * 2, this.wsMaxReconnectDelay);
            this.connectWebSocket();
        }, this.wsReconnectDelay);
    }
    
    sendMessage(message) {
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            this.ws.send(JSON.stringify(message));
        }
    }
    
    // ==================== Message Handling ====================
    
    handleMessage(message) {
        switch (message.type) {
            case 'server_ready':
                this.handleServerReady(message.payload);
                break;
                
            case 'webrtc_offer':
                this.handleWebRTCOffer(message.sdp || message.payload?.sdp);
                break;
                
            case 'ice_candidate':
                this.handleICECandidate(message);
                break;
                
            case 'connection_state':
                this.handleConnectionState(message.state || message.payload?.state);
                break;
                
            case 'config':
                this.handleConfig(message.payload);
                break;
                
            case 'error':
                this.handleError(message.payload?.message || message.message);
                break;
                
            default:
                console.log('Unknown message type:', message.type);
        }
    }
    
    handleServerReady(payload) {
        console.log('Server ready:', payload);
        
        if (payload?.config) {
            this.config = { ...this.config, ...payload.config };
            this.elements.resolution.textContent = `${this.config.width}x${this.config.height}`;
        }
    }
    
    handleConfig(config) {
        if (config) {
            this.config = { ...this.config, ...config };
            this.elements.resolution.textContent = `${this.config.width}x${this.config.height}`;
        }
    }
    
    handleError(message) {
        console.error('Server error:', message);
        this.showConnectionOverlay(message, true);
    }
    
    // ==================== WebRTC ====================
    
    async handleWebRTCOffer(sdp) {
        if (!sdp) {
            console.error('No SDP in offer');
            return;
        }
        
        console.log('Received WebRTC offer');
        
        try {
            // Create peer connection
            this.pc = new RTCPeerConnection({
                iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
                bundlePolicy: 'max-bundle',
                rtcpMuxPolicy: 'require'
            });
            
            // Handle ICE candidates
            this.pc.onicecandidate = (event) => {
                if (event.candidate) {
                    this.sendMessage({
                        type: 'ice_candidate',
                        candidate: event.candidate.candidate,
                        sdpMLineIndex: event.candidate.sdpMLineIndex,
                        sdpMid: event.candidate.sdpMid
                    });
                }
            };
            
            // Handle connection state changes
            this.pc.onconnectionstatechange = () => {
                console.log('Connection state:', this.pc.connectionState);
                this.handleConnectionState(this.pc.connectionState);
            };
            
            this.pc.oniceconnectionstatechange = () => {
                console.log('ICE connection state:', this.pc.iceConnectionState);
            };
            
            // Handle incoming tracks
            this.pc.ontrack = (event) => {
                console.log('Received track:', event.track.kind);
                if (event.track.kind === 'video') {
                    this.remoteStream = event.streams[0];
                    this.elements.video.srcObject = this.remoteStream;
                    this.hideConnectionOverlay();
                }
            };
            
            // Set remote description (offer)
            await this.pc.setRemoteDescription(new RTCSessionDescription({
                type: 'offer',
                sdp: sdp
            }));
            
            // Create and set local description (answer)
            const answer = await this.pc.createAnswer();
            await this.pc.setLocalDescription(answer);
            
            // Send answer
            this.sendMessage({
                type: 'webrtc_answer',
                sdp: answer.sdp
            });
            
            console.log('Sent WebRTC answer');
            
        } catch (error) {
            console.error('WebRTC setup failed:', error);
            this.showConnectionOverlay('WebRTC connection failed', true);
        }
    }
    
    handleICECandidate(message) {
        if (!this.pc) return;
        
        try {
            const candidate = new RTCIceCandidate({
                candidate: message.candidate,
                sdpMLineIndex: message.sdpMLineIndex,
                sdpMid: message.sdpMid
            });
            
            this.pc.addIceCandidate(candidate);
        } catch (error) {
            console.error('Failed to add ICE candidate:', error);
        }
    }
    
    handleConnectionState(state) {
        switch (state) {
            case 'connected':
            case 'completed':
                this.isConnected = true;
                this.updateStatus('connected', 'Connected');
                this.hideConnectionOverlay();
                break;
                
            case 'disconnected':
                this.updateStatus('connecting', 'Reconnecting...');
                break;
                
            case 'failed':
                this.isConnected = false;
                this.updateStatus('disconnected', 'Connection failed');
                this.showConnectionOverlay('Connection failed', true);
                break;
                
            case 'closed':
                this.isConnected = false;
                this.updateStatus('disconnected', 'Disconnected');
                break;
        }
    }
    
    // ==================== Input Handling ====================
    
    setupEventListeners() {
        const overlay = this.elements.overlay;
        
        // Make overlay focusable for keyboard events
        overlay.tabIndex = 0;
        
        // Mouse events
        overlay.addEventListener('mousemove', (e) => this.handleMouseMove(e));
        overlay.addEventListener('mousedown', (e) => this.handleMouseButton(e, true));
        overlay.addEventListener('mouseup', (e) => this.handleMouseButton(e, false));
        overlay.addEventListener('wheel', (e) => this.handleWheel(e), { passive: false });
        overlay.addEventListener('contextmenu', (e) => e.preventDefault());
        overlay.addEventListener('click', () => overlay.focus());
        
        // Keyboard events
        overlay.addEventListener('keydown', (e) => this.handleKey(e, true));
        overlay.addEventListener('keyup', (e) => this.handleKey(e, false));
        
        // Prevent default for some keys
        overlay.addEventListener('keydown', (e) => {
            // Prevent tab from moving focus
            if (e.key === 'Tab') {
                e.preventDefault();
            }
        });
        
        // Control buttons
        this.elements.fullscreenBtn.addEventListener('click', () => this.toggleFullscreen());
        this.elements.controlToggle.addEventListener('click', () => this.toggleControl());
        
        // Video frame counter
        this.elements.video.addEventListener('resize', () => {
            const video = this.elements.video;
            console.log(`Video size: ${video.videoWidth}x${video.videoHeight}`);
        });
        
        // Handle fullscreen change
        document.addEventListener('fullscreenchange', () => {
            this.isFullscreen = !!document.fullscreenElement;
            document.body.classList.toggle('fullscreen', this.isFullscreen);
        });
        
        // Focus overlay on page load
        overlay.focus();
    }
    
    getNormalizedCoordinates(event) {
        const video = this.elements.video;
        const rect = video.getBoundingClientRect();
        
        // Calculate video dimensions within the element (accounting for object-fit: contain)
        const videoAspect = this.config.width / this.config.height;
        const elementAspect = rect.width / rect.height;
        
        let videoWidth, videoHeight, offsetX, offsetY;
        
        if (videoAspect > elementAspect) {
            // Video is wider - letterboxed top/bottom
            videoWidth = rect.width;
            videoHeight = rect.width / videoAspect;
            offsetX = 0;
            offsetY = (rect.height - videoHeight) / 2;
        } else {
            // Video is taller - pillarboxed left/right
            videoHeight = rect.height;
            videoWidth = rect.height * videoAspect;
            offsetX = (rect.width - videoWidth) / 2;
            offsetY = 0;
        }
        
        // Calculate position relative to video content
        const x = event.clientX - rect.left - offsetX;
        const y = event.clientY - rect.top - offsetY;
        
        // Normalize to 0-1 range, clamped
        const xNorm = Math.max(0, Math.min(1, x / videoWidth));
        const yNorm = Math.max(0, Math.min(1, y / videoHeight));
        
        return { xNorm, yNorm };
    }
    
    handleMouseMove(event) {
        if (!this.controlEnabled || !this.isConnected) return;
        
        const { xNorm, yNorm } = this.getNormalizedCoordinates(event);
        const now = performance.now();
        
        // Throttle mouse moves
        if (now - this.lastMouseMoveTime < this.mouseMoveThrottleMs) {
            // Store pending move for later
            this.pendingMouseMove = { xNorm, yNorm };
            
            if (!this.mouseThrottleTimer) {
                this.mouseThrottleTimer = setTimeout(() => {
                    if (this.pendingMouseMove) {
                        this.sendMessage({
                            type: 'mouse_move',
                            ...this.pendingMouseMove
                        });
                        this.pendingMouseMove = null;
                    }
                    this.mouseThrottleTimer = null;
                }, this.mouseMoveThrottleMs);
            }
            return;
        }
        
        this.lastMouseMoveTime = now;
        this.sendMessage({
            type: 'mouse_move',
            xNorm,
            yNorm
        });
    }
    
    handleMouseButton(event, down) {
        if (!this.controlEnabled || !this.isConnected) return;
        
        event.preventDefault();
        
        const { xNorm, yNorm } = this.getNormalizedCoordinates(event);
        
        this.sendMessage({
            type: 'mouse_button',
            button: event.button,
            down,
            xNorm,
            yNorm
        });
    }
    
    handleWheel(event) {
        if (!this.controlEnabled || !this.isConnected) return;
        
        event.preventDefault();
        
        // Normalize scroll deltas
        let deltaX = event.deltaX;
        let deltaY = event.deltaY;
        
        // Handle different deltaMode values
        if (event.deltaMode === 1) { // DOM_DELTA_LINE
            deltaX *= 20;
            deltaY *= 20;
        } else if (event.deltaMode === 2) { // DOM_DELTA_PAGE
            deltaX *= 100;
            deltaY *= 100;
        }
        
        this.sendMessage({
            type: 'mouse_wheel',
            deltaX: Math.round(deltaX),
            deltaY: Math.round(deltaY)
        });
    }
    
    handleKey(event, down) {
        if (!this.controlEnabled || !this.isConnected) return;
        
        // Don't prevent browser shortcuts like Cmd+R
        if (event.metaKey && ['r', 'w', 't', 'n', 'q'].includes(event.key.toLowerCase())) {
            return;
        }
        
        event.preventDefault();
        
        // Update modifier state
        this.modifiers.shift = event.shiftKey;
        this.modifiers.ctrl = event.ctrlKey;
        this.modifiers.alt = event.altKey;
        this.modifiers.meta = event.metaKey;
        
        this.sendMessage({
            type: 'key',
            keyCode: event.code,
            key: event.key,
            down,
            modifiers: { ...this.modifiers }
        });
    }
    
    // ==================== UI Controls ====================
    
    toggleFullscreen() {
        if (!document.fullscreenElement) {
            document.documentElement.requestFullscreen();
        } else {
            document.exitFullscreen();
        }
    }
    
    toggleControl() {
        this.controlEnabled = !this.controlEnabled;
        
        this.elements.controlToggle.classList.toggle('active', this.controlEnabled);
        this.elements.overlay.classList.toggle('control-disabled', !this.controlEnabled);
        
        // Notify server
        this.sendMessage({
            type: this.controlEnabled ? 'start_control' : 'stop_control'
        });
    }
    
    updateStatus(state, text) {
        this.elements.statusIndicator.className = state;
        this.elements.statusText.textContent = text;
    }
    
    showConnectionOverlay(message, isError = false) {
        this.elements.connectionOverlay.classList.remove('hidden');
        this.elements.connectionOverlay.classList.toggle('error', isError);
        this.elements.connectionMessage.textContent = message;
    }
    
    hideConnectionOverlay() {
        this.elements.connectionOverlay.classList.add('hidden');
    }
    
    // ==================== Stats ====================
    
    startStatsUpdater() {
        setInterval(() => this.updateStats(), 1000);
    }
    
    async updateStats() {
        if (!this.pc) return;
        
        try {
            const stats = await this.pc.getStats();
            
            stats.forEach(report => {
                if (report.type === 'inbound-rtp' && report.kind === 'video') {
                    const framesReceived = report.framesReceived || 0;
                    const now = Date.now();
                    const elapsed = (now - this.stats.lastStatsTime) / 1000;
                    
                    if (elapsed > 0) {
                        this.stats.fps = Math.round((framesReceived - this.stats.framesReceived) / elapsed);
                        this.elements.fps.textContent = `${this.stats.fps} fps`;
                    }
                    
                    this.stats.framesReceived = framesReceived;
                    this.stats.lastStatsTime = now;
                    
                    // Update resolution if available
                    if (report.frameWidth && report.frameHeight) {
                        this.elements.resolution.textContent = `${report.frameWidth}x${report.frameHeight}`;
                    }
                }
                
                if (report.type === 'candidate-pair' && report.state === 'succeeded') {
                    if (report.currentRoundTripTime) {
                        const latency = Math.round(report.currentRoundTripTime * 1000);
                        this.elements.latency.textContent = `${latency} ms`;
                    }
                }
            });
        } catch (error) {
            // Stats not available
        }
    }
}

// Initialize client when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    window.vmClient = new VirtualMonitorClient();
});
