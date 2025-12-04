# Virtual Monitor

A macOS application that creates a virtual monitor accessible from any browser on your LAN. It captures your screen at 4K@60fps, encodes it with H.264, and streams via WebRTC for ultra-low latency remote access with full mouse and keyboard control.

## Features

- **4K@60fps Screen Capture**: Uses ScreenCaptureKit for high-quality, low-latency capture
- **Hardware H.264 Encoding**: VideoToolbox acceleration for efficient encoding
- **WebRTC Streaming**: Sub-second latency video streaming to browser
- **Full Input Control**: Mouse and keyboard events are sent back and injected into macOS
- **Single-Client Model**: One active client at a time for security
- **LAN-Optimized**: Designed for local network use with high bitrates

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later (for building)
- Swift 5.9+

## Building

### Using Swift Package Manager

```bash
cd "Virtual Monitor"
swift build -c release
```

### Using Xcode

1. Open the project folder in Xcode
2. Select Product → Build
3. The executable will be in `.build/release/VirtualMonitor`

## Running

### First Run - Grant Permissions

The app requires two permissions:

1. **Screen Recording**: Required for capturing your screen
2. **Accessibility**: Required for injecting mouse/keyboard events

On first run, macOS will prompt you to grant these permissions. You can also pre-configure them in:
- System Preferences → Privacy & Security → Screen Recording
- System Preferences → Privacy & Security → Accessibility

### Starting the Server

```bash
# Default port 8080
.build/release/VirtualMonitor

# Custom port
VM_PORT=9000 .build/release/VirtualMonitor

# With authentication token
VM_AUTH_TOKEN=mysecrettoken .build/release/VirtualMonitor

# Custom bitrate (Mbps)
VM_BITRATE_MBPS=30 .build/release/VirtualMonitor
```

### Connecting from Browser

1. On any device on the same network, open a browser
2. Navigate to `http://<mac-ip>:8080/`
3. If using auth token: `http://<mac-ip>:8080/?token=mysecrettoken`
4. Wait for WebRTC connection to establish
5. You should see your Mac's screen with full control

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `VM_PORT` | 8080 | HTTP/WebSocket server port |
| `VM_AUTH_TOKEN` | (none) | Optional authentication token |
| `VM_BITRATE_MBPS` | 25 | H.264 encoder bitrate in Mbps |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        VirtualMonitor                            │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────┐     │
│  │ScreenCapture│───▶│ H.264 Encoder│───▶│ WebRTC Manager  │     │
│  │   Kit       │    │ (VideoToolbox)│    │   (libwebrtc)   │     │
│  └─────────────┘    └──────────────┘    └────────┬────────┘     │
│                                                   │              │
│                                                   ▼              │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────┐     │
│  │   Input     │◀───│  WebSocket   │◀───│  SwiftNIO HTTP  │     │
│  │  Injector   │    │   Handler    │    │     Server      │     │
│  └─────────────┘    └──────────────┘    └─────────────────┘     │
│         │                  ▲                      ▲              │
│         ▼                  │                      │              │
│  ┌─────────────┐           │                      │              │
│  │   CGEvent   │           │                      │              │
│  │    APIs     │           │                      │              │
│  └─────────────┘           │                      │              │
└────────────────────────────┼──────────────────────┼──────────────┘
                             │                      │
                             │      Network         │
                             ▼                      ▼
                    ┌─────────────────────────────────────┐
                    │           Web Browser               │
                    │  ┌──────────┐   ┌─────────────┐     │
                    │  │ WebRTC   │   │  WebSocket  │     │
                    │  │  Video   │   │   Input     │     │
                    │  └──────────┘   └─────────────┘     │
                    └─────────────────────────────────────┘
```

## Components

### Screen Capture (ScreenCaptureKit)
- Captures the main display at 4K resolution
- Configurable to 60fps target
- GPU-accelerated scaling if source differs from 4K

### H.264 Encoder (VideoToolbox)
- Hardware-accelerated H.264 encoding
- Low-latency profile with minimal B-frames
- Real-time mode with frame dropping under load

### WebRTC Manager
- Creates peer connection and video track
- Handles SDP offer/answer exchange
- ICE candidate gathering and exchange

### HTTP/WebSocket Server (SwiftNIO)
- Serves the HTML/JS client
- WebSocket endpoint for signaling and input
- Single-threaded, high-performance event loop

### Input Injector
- Maps browser key codes to macOS virtual keycodes
- Injects mouse move, click, scroll events
- Rate-limited to prevent event flooding

### Session Manager
- Enforces single-client model
- Tracks active sessions
- Handles graceful disconnect

## Security Considerations

This application is designed for **LAN use only**. Security measures include:

- Optional token-based authentication
- Single-client model (rejects additional connections)
- Rate-limiting on input events
- No TLS (acceptable for LAN; not for internet)

**Do NOT expose this to the internet** without additional security measures.

## Troubleshooting

### "Screen recording permission not granted"
Go to System Preferences → Privacy & Security → Screen Recording and enable VirtualMonitor.

### "Accessibility permission not granted"
Go to System Preferences → Privacy & Security → Accessibility and enable VirtualMonitor.

### Video is choppy
- Increase bitrate: `VM_BITRATE_MBPS=35`
- Check network bandwidth between devices
- Ensure devices are on same LAN segment

### High latency
- WebRTC should achieve <100ms on LAN
- Check for network congestion
- Try wired Ethernet instead of WiFi

### Mouse/keyboard not working
- Verify Accessibility permission is granted
- Check that control is enabled (🖱️ button in UI)
- Restart the app after granting permissions

## License

MIT License - See LICENSE file for details.
