@_exported import VisynTransport
import ReplayKit
import UIKit

@MainActor
public final class VisynCaptureController {
    public var onStateChange: ((VisynBroadcastState) -> Void)?
    public var onFrame: ((VisynCapturedFrame) -> Void)?
    public var onPictureInPictureChange: ((Bool) -> Void)?
    public var onError: ((Error) -> Void)?
    public private(set) var state = VisynBroadcastState.stopped
    public var isPictureInPictureActive: Bool { pip.isActive }
    /// Content layout size in points, not the system-managed floating window's size.
    public var pictureInPictureContentSize: CGSize { pip.contentSize }

    private let configuration: VisynConfiguration
    private let channel: VisynWormholeChannel
    /// 当前生效的路线。视频通话路线启动失败时回退到采样缓冲路线，这里随之改变。
    private var pip: any VisynPictureInPicturePresenting
    private let requestedRoute: VisynPictureInPictureRoute
    /// 回退到采样缓冲路线时要用同一份内容视图与帧率。
    private let pipContent: UIView
    private let framesPerSecond: Int
    private let audioSession: VisynPictureInPictureAudioSession
    private weak var pipHost: UIView?
    private var sessionID: UUID?
    private var lastFrameID: UUID?
    private var timer: Timer?
    private var picker: RPSystemBroadcastPickerView?

    /// Frame rate must be within 1...30. The default preserves the low-cost text-only refresh rate.
    ///
    /// `pictureInPictureRoute` 默认用采样缓冲路线（后台稳定、只定宽高比）；
    /// 传 `.videoCall` 改用视频通话式小窗：没有播放控件，`preferredContentSize` 决定小窗的
    /// 尺寸与宽高比，但需要系统认为「通话在进行中」，启动失败会自动回退到采样缓冲路线。
    public init(configuration: VisynConfiguration, pictureInPictureContent: UIView,
                pictureInPictureContentSize: CGSize = VisynPictureInPictureSize.landscape,
                pictureInPictureFramesPerSecond: Int = 2,
                pictureInPictureRoute: VisynPictureInPictureRoute = .sampleBuffer,
                pictureInPictureAudioSession: VisynPictureInPictureAudioSession? = nil) throws {
        self.configuration = configuration
        requestedRoute = pictureInPictureRoute
        pipContent = pictureInPictureContent
        framesPerSecond = pictureInPictureFramesPerSecond
        // 视频通话路线默认用通话形态的音频会话，采样缓冲路线默认只播放。
        let audio = pictureInPictureAudioSession
            ?? (pictureInPictureRoute == .videoCall ? .videoCall : .playback)
        audioSession = audio
        pip = try Self.makePresenter(route: pictureInPictureRoute, content: pictureInPictureContent,
                                     size: pictureInPictureContentSize,
                                     framesPerSecond: pictureInPictureFramesPerSecond,
                                     audioSession: audio)
        channel = try VisynWormholeChannel(configuration: configuration)
    }

    private static func makePresenter(
        route: VisynPictureInPictureRoute, content: UIView, size: CGSize, framesPerSecond: Int,
        audioSession: VisynPictureInPictureAudioSession
    ) throws -> any VisynPictureInPicturePresenting {
        switch route {
        case .sampleBuffer:
            return try VisynPictureInPicturePresenter(content: content, contentSize: size,
                                                      framesPerSecond: framesPerSecond,
                                                      audioSession: audioSession)
        case .videoCall:
            return try VisynVideoCallPresenter(content: content, contentSize: size,
                                               framesPerSecond: framesPerSecond,
                                               audioSession: audioSession)
        }
    }

    /// 当前实际使用的路线，可能因回退与请求值不同。
    public var pictureInPictureRoute: VisynPictureInPictureRoute {
        pip is VisynVideoCallPresenter ? .videoCall : .sampleBuffer
    }

    deinit {
        timer?.invalidate()
        channel.stopListening()
    }

    public func prepare(on host: UIView) {
        guard timer == nil else { return }
        pipHost = host
        do { try prepare(pip, on: host) } catch { onError?(error) }
        channel.listen(to: .status) { [weak self] in
            Task { @MainActor in self?.refreshStatus() }
        }
        channel.listen(to: .frame) { [weak self] in
            Task { @MainActor in self?.consumeFrame() }
        }
        // Poll also recovers notifications missed while the app was suspended, and detects extension death.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
                self?.consumeFrame()
            }
        }
        refreshStatus()
        consumeFrame()
    }

    /// The same system panel starts or stops the broadcast. System confirmation is always required.
    public func showBroadcastPicker(on host: UIView) {
        guard let window = host.window else { return }
        if picker == nil {
            let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            picker.preferredExtension = configuration.broadcastExtensionIdentifier
            picker.showsMicrophoneButton = false
            picker.isHidden = true
            self.picker = picker
        }
        guard let picker else { return }
        window.addSubview(picker)
        guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else {
            onError?(VisynError.invalidConfiguration)
            return
        }
        button.sendActions(for: .touchUpInside)
    }

    /// 挂上回调；视频通话路线额外接上回退。
    private func prepare(_ presenter: any VisynPictureInPicturePresenting, on host: UIView) throws {
        presenter.onChange = { [weak self] active in self?.onPictureInPictureChange?(active) }
        presenter.onError = { [weak self] error in self?.onError?(error) }
        if let videoCall = presenter as? VisynVideoCallPresenter {
            videoCall.onRouteUnavailable = { [weak self] _ in
                Task { @MainActor in self?.fallBackToSampleBuffer() }
            }
        }
        try presenter.prepare(on: host)
    }

    /// 视频通话路线被系统拒绝（通常是没有进行中的通话）时换回采样缓冲路线。
    private func fallBackToSampleBuffer() {
        guard pip is VisynVideoCallPresenter, requestedRoute == .videoCall else { return }
        let size = pip.contentSize
        let wasActive = pip.isActive
        pip.stop()
        guard let presenter = try? VisynPictureInPicturePresenter(
            content: pipContent, contentSize: size, framesPerSecond: framesPerSecond,
            audioSession: .playback) else { return }
        pip = presenter
        guard let pipHost else { return }
        do { try prepare(presenter, on: pipHost) } catch { onError?(error); return }
        if wasActive { presenter.start() }
    }

    /// 关闭小窗（已关闭时是空操作）。改路线前调用，避免旧路线的会话残留。
    public func stopPictureInPicture() {
        guard pip.isActive else { return }
        pip.stop()
    }

    public func togglePictureInPicture() {
        if pip.isActive { pip.stop() } else { pip.start() }
    }

    /// Updates the content's dimensions and aspect ratio, including while PiP is active.
    /// Each dimension must be finite and within 1...640 points, and is rounded to a whole point.
    /// Persistence is opt-in through VisynPictureInPictureSize.save(_:to:forKey:).
    /// iOS controls the floating window's actual size; the user resizes it with a pinch gesture.
    public func setPictureInPictureContentSize(_ size: CGSize) throws {
        try pip.setContentSize(size)
    }

    private func refreshStatus() {
        do {
            let status = try channel.read(VisynBroadcastStatus.self, from: .status)
            let next = status?.isCurrent() == true ? status?.state ?? .stopped : .stopped
            let newSession = sessionID != status?.sessionID
            sessionID = status?.sessionID
            guard state != next || newSession else { return }
            state = next
            onStateChange?(next)
            if next == .broadcasting { pip.start() }
            else if next == .stopped {
                channel.clear(.frame)
                pip.stop()
            }
        } catch {
            channel.clear(.status)
            state = .stopped
            pip.stop()
            onStateChange?(.stopped)
            onError?(error)
        }
    }

    private func consumeFrame() {
        do {
            guard let frame = try channel.read(VisynCapturedFrame.self, from: .frame) else { return }
            defer { channel.clear(.frame) }
            guard state == .broadcasting, frame.sessionID == sessionID, frame.id != lastFrameID else { return }
            // Expired mailbox frames are normal when the app returns from suspension.
            guard (try? frame.validate()) != nil else { return }
            lastFrameID = frame.id
            onFrame?(frame)
        } catch {
            channel.clear(.frame)
            onError?(error)
        }
    }
}
