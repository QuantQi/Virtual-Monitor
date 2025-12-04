import Foundation
import CoreGraphics
import ApplicationServices
import Logging

/// Handles injection of mouse and keyboard events into macOS
final class InputInjector: @unchecked Sendable {
    static let shared = InputInjector()
    
    private let logger = Logger(label: "com.virtualmonitor.input")
    private let config = AppConfiguration.shared
    
    // Rate limiting
    private var lastEventTime: Date = Date()
    private let minEventInterval: TimeInterval
    private var eventCount: UInt64 = 0
    
    // Current mouse position (in 4K coordinates)
    private var currentMouseX: CGFloat = 0
    private var currentMouseY: CGFloat = 0
    
    // Safety control
    private var isEnabled = true
    private let inputLock = NSLock()
    
    // Key mapping from browser codes to macOS key codes
    private let keyCodeMap: [String: CGKeyCode]
    
    private init() {
        minEventInterval = 1.0 / Double(config.maxInputEventsPerSecond)
        keyCodeMap = Self.buildKeyCodeMap()
    }
    
    /// Check if accessibility permission is granted
    static func checkPermission() -> Bool {
        // This will prompt for permission if not granted
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        return AXIsProcessTrustedWithOptions(options)
    }
    
    /// Enable or disable input injection
    func setEnabled(_ enabled: Bool) {
        inputLock.lock()
        defer { inputLock.unlock() }
        
        isEnabled = enabled
        logger.info("Input injection \(enabled ? "enabled" : "disabled")")
    }
    
    // MARK: - Mouse Injection
    
    /// Inject mouse move event
    func injectMouseMove(xNorm: Double, yNorm: Double) {
        guard config.enableMouseInjection else { return }
        
        // Skip rate limiting check for mouse moves to reduce lag
        // Instead, just ensure we're enabled
        inputLock.lock()
        guard isEnabled else {
            inputLock.unlock()
            return
        }
        inputLock.unlock()
        
        // Convert normalized coordinates directly to screen coordinates
        let point = convertNormalizedToScreen(xNorm: xNorm, yNorm: yNorm)
        
        // Update current position
        currentMouseX = point.x
        currentMouseY = point.y
        
        guard let event = CGEvent(mouseEventSource: nil,
                                   mouseType: .mouseMoved,
                                   mouseCursorPosition: point,
                                   mouseButton: .left) else {
            return
        }
        
        event.post(tap: .cghidEventTap)
        eventCount += 1
    }
    
    /// Inject mouse button event
    func injectMouseButton(button: Int, down: Bool, xNorm: Double, yNorm: Double) {
        guard config.enableMouseInjection, shouldAllowEvent() else { return }
        
        // Convert normalized coordinates directly to screen coordinates
        let point = convertNormalizedToScreen(xNorm: xNorm, yNorm: yNorm)
        
        // Determine event type and button
        let (eventType, mouseButton): (CGEventType, CGMouseButton)
        
        switch button {
        case 0: // Left button
            eventType = down ? .leftMouseDown : .leftMouseUp
            mouseButton = .left
        case 1: // Middle button
            eventType = down ? .otherMouseDown : .otherMouseUp
            mouseButton = .center
        case 2: // Right button
            eventType = down ? .rightMouseDown : .rightMouseUp
            mouseButton = .right
        default:
            return
        }
        
        guard let event = CGEvent(mouseEventSource: nil,
                                   mouseType: eventType,
                                   mouseCursorPosition: point,
                                   mouseButton: mouseButton) else {
            return
        }
        
        // Set click count for double-click detection
        if down {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        
        event.post(tap: .cghidEventTap)
        eventCount += 1
    }
    
    /// Inject mouse wheel event
    func injectMouseWheel(deltaX: Double, deltaY: Double) {
        guard config.enableMouseInjection, shouldAllowEvent() else { return }
        
        // Scale deltas for macOS (typically needs smaller values)
        let scaledDeltaX = Int32(deltaX / 10.0)
        let scaledDeltaY = Int32(-deltaY / 10.0) // Invert Y for natural scrolling
        
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                   units: .pixel,
                                   wheelCount: 2,
                                   wheel1: scaledDeltaY,
                                   wheel2: scaledDeltaX,
                                   wheel3: 0) else {
            return
        }
        
        event.post(tap: .cghidEventTap)
        eventCount += 1
    }
    
    // MARK: - Keyboard Injection
    
    /// Inject keyboard event
    func injectKey(keyCode: String, down: Bool, modifiers: [String: Bool]) {
        guard config.enableKeyboardInjection, shouldAllowEvent() else { return }
        
        // Map browser key code to macOS key code
        guard let macKeyCode = keyCodeMap[keyCode] else {
            logger.debug("Unknown key code: \(keyCode)")
            return
        }
        
        guard let event = CGEvent(keyboardEventSource: nil,
                                   virtualKey: macKeyCode,
                                   keyDown: down) else {
            return
        }
        
        // Set modifier flags
        var flags = CGEventFlags()
        
        if modifiers["shift"] == true {
            flags.insert(.maskShift)
        }
        if modifiers["ctrl"] == true || modifiers["control"] == true {
            flags.insert(.maskControl)
        }
        if modifiers["alt"] == true || modifiers["option"] == true {
            flags.insert(.maskAlternate)
        }
        if modifiers["meta"] == true || modifiers["command"] == true {
            flags.insert(.maskCommand)
        }
        
        event.flags = flags
        event.post(tap: .cghidEventTap)
        eventCount += 1
    }
    
    // MARK: - Coordinate Conversion
    
    /// Convert normalized coordinates (0-1) directly to actual screen coordinates
    private func convertNormalizedToScreen(xNorm: Double, yNorm: Double) -> CGPoint {
        // Get the main display bounds
        let mainDisplay = CGMainDisplayID()
        let displayBounds = CGDisplayBounds(mainDisplay)
        
        // Map normalized coordinates directly to screen coordinates
        // This avoids any intermediate scaling issues
        let screenX = displayBounds.origin.x + (CGFloat(xNorm) * displayBounds.width)
        let screenY = displayBounds.origin.y + (CGFloat(yNorm) * displayBounds.height)
        
        return CGPoint(x: screenX, y: screenY)
    }
    
    /// Convert 4K coordinates to actual screen coordinates (legacy, kept for compatibility)
    private func convertToScreenCoordinates(x: CGFloat, y: CGFloat) -> CGPoint {
        // Get the main display bounds
        let mainDisplay = CGMainDisplayID()
        let displayBounds = CGDisplayBounds(mainDisplay)
        
        // Scale from 4K to actual display resolution
        let scaleX = displayBounds.width / CGFloat(config.streamWidth)
        let scaleY = displayBounds.height / CGFloat(config.streamHeight)
        
        let screenX = displayBounds.origin.x + (x * scaleX)
        let screenY = displayBounds.origin.y + (y * scaleY)
        
        return CGPoint(x: screenX, y: screenY)
    }
    
    // MARK: - Rate Limiting
    
    /// Check if event should be allowed (rate limiting and safety)
    private func shouldAllowEvent() -> Bool {
        inputLock.lock()
        defer { inputLock.unlock() }
        
        guard isEnabled else { return false }
        
        let now = Date()
        let elapsed = now.timeIntervalSince(lastEventTime)
        
        if elapsed < minEventInterval {
            return false
        }
        
        lastEventTime = now
        return true
    }
    
    /// Get event statistics
    var statistics: InputStatistics {
        InputStatistics(
            isEnabled: isEnabled,
            eventCount: eventCount,
            maxEventsPerSecond: config.maxInputEventsPerSecond
        )
    }
    
    // MARK: - Key Code Mapping
    
    /// Build mapping from browser key codes to macOS virtual key codes
    private static func buildKeyCodeMap() -> [String: CGKeyCode] {
        var map: [String: CGKeyCode] = [:]
        
        // Letters A-Z
        let letters: [(String, CGKeyCode)] = [
            ("KeyA", 0x00), ("KeyS", 0x01), ("KeyD", 0x02), ("KeyF", 0x03),
            ("KeyH", 0x04), ("KeyG", 0x05), ("KeyZ", 0x06), ("KeyX", 0x07),
            ("KeyC", 0x08), ("KeyV", 0x09), ("KeyB", 0x0B), ("KeyQ", 0x0C),
            ("KeyW", 0x0D), ("KeyE", 0x0E), ("KeyR", 0x0F), ("KeyY", 0x10),
            ("KeyT", 0x11), ("KeyO", 0x1F), ("KeyU", 0x20), ("KeyI", 0x22),
            ("KeyP", 0x23), ("KeyL", 0x25), ("KeyJ", 0x26), ("KeyK", 0x28),
            ("KeyN", 0x2D), ("KeyM", 0x2E)
        ]
        
        for (code, keyCode) in letters {
            map[code] = keyCode
        }
        
        // Numbers 0-9
        let numbers: [(String, CGKeyCode)] = [
            ("Digit1", 0x12), ("Digit2", 0x13), ("Digit3", 0x14), ("Digit4", 0x15),
            ("Digit5", 0x17), ("Digit6", 0x16), ("Digit7", 0x1A), ("Digit8", 0x1C),
            ("Digit9", 0x19), ("Digit0", 0x1D)
        ]
        
        for (code, keyCode) in numbers {
            map[code] = keyCode
        }
        
        // Special keys
        map["Space"] = 0x31
        map["Enter"] = 0x24
        map["NumpadEnter"] = 0x4C
        map["Tab"] = 0x30
        map["Backspace"] = 0x33
        map["Delete"] = 0x75
        map["Escape"] = 0x35
        
        // Modifiers
        map["ShiftLeft"] = 0x38
        map["ShiftRight"] = 0x3C
        map["ControlLeft"] = 0x3B
        map["ControlRight"] = 0x3E
        map["AltLeft"] = 0x3A
        map["AltRight"] = 0x3D
        map["MetaLeft"] = 0x37
        map["MetaRight"] = 0x36
        map["CapsLock"] = 0x39
        
        // Arrow keys
        map["ArrowUp"] = 0x7E
        map["ArrowDown"] = 0x7D
        map["ArrowLeft"] = 0x7B
        map["ArrowRight"] = 0x7C
        
        // Navigation
        map["Home"] = 0x73
        map["End"] = 0x77
        map["PageUp"] = 0x74
        map["PageDown"] = 0x79
        
        // Function keys
        map["F1"] = 0x7A
        map["F2"] = 0x78
        map["F3"] = 0x63
        map["F4"] = 0x76
        map["F5"] = 0x60
        map["F6"] = 0x61
        map["F7"] = 0x62
        map["F8"] = 0x64
        map["F9"] = 0x65
        map["F10"] = 0x6D
        map["F11"] = 0x67
        map["F12"] = 0x6F
        
        // Punctuation and symbols
        map["Minus"] = 0x1B
        map["Equal"] = 0x18
        map["BracketLeft"] = 0x21
        map["BracketRight"] = 0x1E
        map["Backslash"] = 0x2A
        map["Semicolon"] = 0x29
        map["Quote"] = 0x27
        map["Backquote"] = 0x32
        map["Comma"] = 0x2B
        map["Period"] = 0x2F
        map["Slash"] = 0x2C
        
        // Numpad
        map["Numpad0"] = 0x52
        map["Numpad1"] = 0x53
        map["Numpad2"] = 0x54
        map["Numpad3"] = 0x55
        map["Numpad4"] = 0x56
        map["Numpad5"] = 0x57
        map["Numpad6"] = 0x58
        map["Numpad7"] = 0x59
        map["Numpad8"] = 0x5B
        map["Numpad9"] = 0x5C
        map["NumpadDecimal"] = 0x41
        map["NumpadMultiply"] = 0x43
        map["NumpadAdd"] = 0x45
        map["NumpadSubtract"] = 0x4E
        map["NumpadDivide"] = 0x4B
        map["NumpadEqual"] = 0x51
        map["NumLock"] = 0x47
        
        return map
    }
}

// MARK: - Supporting Types

struct InputStatistics {
    let isEnabled: Bool
    let eventCount: UInt64
    let maxEventsPerSecond: Int
}
