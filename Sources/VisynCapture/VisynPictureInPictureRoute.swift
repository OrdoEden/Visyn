import AVKit
import UIKit
import VisynTransport

/// 画中画的两条实现路线。
///
/// - `sampleBuffer`：把内容视图离屏光栅化成 CMSampleBufferDisplayLayer 的帧，用
///   `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`。
///   内容尺寸只能定宽高比，小窗实际大小完全由系统决定，且 iOS 会带播放/暂停控件。
/// - `videoCall`：把内容视图挂进 `AVPictureInPictureVideoCallViewController`，
///   用 `ContentSource(activeVideoCallSourceView:contentViewController:)`。
///   这条路没有播放器控件，`preferredContentSize` 同时决定小窗的尺寸与宽高比，
///   内容是真视图层次、由系统直接合成，不需要逐帧光栅化。
public enum VisynPictureInPictureRoute: Sendable {
    case sampleBuffer
    /// `size` 传给通话内容控制器的 `preferredContentSize`；`size` 为 nil 时沿用内容尺寸。
    case videoCall
}

/// 视频通话路线要求音频会话处于「通话中」形态：`.playback` 通常不足以让系统
/// 认作通话，小窗会被拒绝。这是接入方需要按自己 App 的音频策略选的开关，
/// 库不擅自改。
public enum VisynPictureInPictureAudioSession: Sendable {
    /// 采样缓冲路线的默认值：只播放、可与其它音频混音。
    case playback
    /// 视频通话路线建议值：通话形态的音频会话，会打断其它音频。
    case videoCall
}

/// 两条路线共同的行为，供 `VisynCaptureController` 面向协议使用。
@MainActor
protocol VisynPictureInPicturePresenting: AnyObject {
    var onChange: ((Bool) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var isActive: Bool { get }
    var contentSize: CGSize { get }

    func prepare(on host: UIView) throws
    func start()
    func stop()
    func setContentSize(_ size: CGSize) throws
}

// MARK: - 路线的标题与本地保存

extension VisynPictureInPictureRoute {
    public struct Preset: Equatable, Sendable {
        public let title: String
        public let route: VisynPictureInPictureRoute
    }

    /// 接入 App 的设置页可直接用来生成选项。
    public static let presets = [
        Preset(title: "标准（可后台）", route: .sampleBuffer),
        Preset(title: "通话式（无控件）", route: .videoCall)
    ]
    public static let userDefaultsKey = "Visyn.pictureInPictureRoute"

    /// 存的是路线名；未知值当作未保存。
    private var storageValue: String {
        switch self {
        case .sampleBuffer: return "sampleBuffer"
        case .videoCall: return "videoCall"
        }
    }

    public func save(to defaults: UserDefaults = .standard, forKey key: String = userDefaultsKey) {
        defaults.set(storageValue, forKey: key)
    }

    /// 返回 nil 表示没有保存过；调用方决定默认值。
    public static func load(from defaults: UserDefaults = .standard,
                            forKey key: String = userDefaultsKey) -> VisynPictureInPictureRoute? {
        switch defaults.string(forKey: key) {
        case "sampleBuffer": return .sampleBuffer
        case "videoCall": return .videoCall
        default: return nil
        }
    }
}
