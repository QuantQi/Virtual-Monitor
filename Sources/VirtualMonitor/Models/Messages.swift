import Foundation

/// Message types for WebSocket signaling
enum SignalingMessageType: String, Codable {
    case serverReady = "server_ready"
    case clientReady = "client_ready"
    case webrtcOffer = "webrtc_offer"
    case webrtcAnswer = "webrtc_answer"
    case iceCandidate = "ice_candidate"
    case connectionState = "connection_state"
    case error = "error"
    case config = "config"
    case stats = "stats"
}

/// Signaling message structure
struct SignalingMessage: Codable {
    let type: SignalingMessageType
    let payload: [String: AnyCodable]
    
    init(type: SignalingMessageType, payload: [String: Any]) {
        self.type = type
        self.payload = payload.mapValues { AnyCodable($0) }
    }
}

/// Type-erased Codable wrapper for JSON values
struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let int32 as Int32:
            try container.encode(Int(int32))
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encode(String(describing: value))
        }
    }
}

/// Input event types from browser
enum InputEventType: String, Codable {
    case mouseMove = "mouse_move"
    case mouseButton = "mouse_button"
    case mouseWheel = "mouse_wheel"
    case key = "key"
}

/// Mouse button identifiers
enum MouseButton: Int, Codable {
    case left = 0
    case middle = 1
    case right = 2
}

/// Modifier keys
struct ModifierKeys: OptionSet, Codable {
    let rawValue: Int
    
    static let shift = ModifierKeys(rawValue: 1 << 0)
    static let control = ModifierKeys(rawValue: 1 << 1)
    static let option = ModifierKeys(rawValue: 1 << 2)  // Alt
    static let command = ModifierKeys(rawValue: 1 << 3)
    static let capsLock = ModifierKeys(rawValue: 1 << 4)
    
    init(rawValue: Int) {
        self.rawValue = rawValue
    }
    
    init(from dict: [String: Bool]) {
        var value = 0
        if dict["shift"] == true { value |= ModifierKeys.shift.rawValue }
        if dict["ctrl"] == true || dict["control"] == true { value |= ModifierKeys.control.rawValue }
        if dict["alt"] == true || dict["option"] == true { value |= ModifierKeys.option.rawValue }
        if dict["meta"] == true || dict["command"] == true { value |= ModifierKeys.command.rawValue }
        if dict["capsLock"] == true { value |= ModifierKeys.capsLock.rawValue }
        self.rawValue = value
    }
}
