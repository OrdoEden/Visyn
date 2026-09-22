import Foundation

public struct VisynConfiguration: Sendable {
    public let appGroupIdentifier: String
    public let broadcastExtensionIdentifier: String

    public init(appGroupIdentifier: String, broadcastExtensionIdentifier: String) {
        self.appGroupIdentifier = appGroupIdentifier
        self.broadcastExtensionIdentifier = broadcastExtensionIdentifier
    }

    public static func load(from bundle: Bundle = .main) throws -> Self {
        guard let group = bundle.object(forInfoDictionaryKey: "VisynAppGroupIdentifier") as? String,
              group.hasPrefix("group."),
              let identifier = bundle.object(forInfoDictionaryKey: "VisynExtensionIdentifier") as? String,
              !identifier.isEmpty else {
            throw VisynError.invalidConfiguration
        }
        return Self(appGroupIdentifier: group, broadcastExtensionIdentifier: identifier)
    }
}

public enum VisynError: LocalizedError {
    case invalidConfiguration, missingAppGroup(String), invalidMessage, writeFailed, missingVideo, pipUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "请配置两端的 VisynAppGroupIdentifier 和 VisynExtensionIdentifier。"
        case .missingAppGroup(let group): return "无法访问共享容器 \(group)，请检查两个 Target 的 App Groups 和签名。"
        case .invalidMessage: return "录屏扩展返回的数据无效或已过期。"
        case .writeFailed: return "无法写入录屏共享数据。"
        case .missingVideo: return "画中画资源未加载。"
        case .pipUnavailable: return "当前无法开启画中画。"
        }
    }
}

public enum VisynBroadcastState: String, Codable, Sendable {
    case stopped, broadcasting, paused
}

/// Lease refreshed by the extension; a terminated extension cannot leave the UI recording forever.
public struct VisynBroadcastStatus: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let state: VisynBroadcastState
    public let updatedAt: Date

    public init(sessionID: UUID, state: VisynBroadcastState, updatedAt: Date = Date()) {
        self.sessionID = sessionID
        self.state = state
        self.updatedAt = updatedAt
    }

    public func isCurrent(at now: Date = Date()) -> Bool {
        (-1...6).contains(now.timeIntervalSince(updatedAt))
    }
}

/// JPEG pixels are already rotated upright. No OCR or model inference runs in the extension.
public struct VisynCapturedFrame: Codable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let capturedAt: Date
    public let width: Int
    public let height: Int
    public let jpegData: Data

    public init(sessionID: UUID, capturedAt: Date = Date(), width: Int, height: Int, jpegData: Data) {
        self.id = UUID()
        self.sessionID = sessionID
        self.capturedAt = capturedAt
        self.width = width
        self.height = height
        self.jpegData = jpegData
    }

    public func validate(at now: Date = Date()) throws {
        guard (1...1280).contains(width), (1...1280).contains(height),
              !jpegData.isEmpty, jpegData.count <= 2_000_000,
              (-1...3).contains(now.timeIntervalSince(capturedAt)) else {
            throw VisynError.invalidMessage
        }
    }
}
