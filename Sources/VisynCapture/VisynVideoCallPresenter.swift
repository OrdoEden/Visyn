import AVKit
import UIKit
import VisynTransport

/// 视频通话式画中画的容器：系统把小窗里显示的就是这个控制器的视图。
///
/// 与采样缓冲路线不同，这里不需要逐帧光栅化——小窗直接合成真实视图层次，
/// 因此没有播放/暂停与进度控件，`preferredContentSize` 同时决定小窗的尺寸与宽高比。
@MainActor
final class VisynVideoCallContentViewController: AVPictureInPictureVideoCallViewController {
    /// 内容视图的落位与回收交给 presenter，控制器只转发出现/消失。
    var onAppear: (() -> Void)?
    var onDisappear: (() -> Void)?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        onAppear?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}

/// 用 `activeVideoCallSourceView` + `AVPictureInPictureVideoCallViewController` 呈现小窗。
///
/// 这条路要求「通话在进行中」，所以只在 `VisynPictureInPictureRoute.videoCall` 下启用；
/// 内容视图在小窗出现时移进通话控制器的视图，小窗关闭后移回宿主视图，
/// 保证 App 内联显示与小窗显示是同一份内容（也因此不能同时出现在两处）。
@MainActor
final class VisynVideoCallPresenter: NSObject, VisynPictureInPicturePresenting,
                                     AVPictureInPictureControllerDelegate {
    var onChange: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?
    /// 视频通话路线启动失败时的回退提示：宿主可据此改用采样缓冲路线。
    var onRouteUnavailable: ((Error) -> Void)?

    private let content: UIView
    private let callViewController = VisynVideoCallContentViewController()
    private var controller: AVPictureInPictureController?
    private weak var host: UIView?
    private var possibleObservation: NSKeyValueObservation?
    private var frameTimer: Timer?
    private let framesPerSecond: Int
    private let audioSession: VisynPictureInPictureAudioSession
    private(set) var contentSize: CGSize

    var isActive: Bool { controller?.isPictureInPictureActive == true }
    /// 内容当前是否被移进了小窗控制器。
    private var isHostingInCallView: Bool { content.superview === callViewController.view }

    init(content: UIView, contentSize: CGSize, framesPerSecond: Int,
         audioSession: VisynPictureInPictureAudioSession = .videoCall) throws {
        guard (1...30).contains(framesPerSecond) else { throw VisynError.invalidConfiguration }
        self.content = content
        self.contentSize = try VisynPictureInPictureSize.validated(contentSize)
        self.framesPerSecond = framesPerSecond
        self.audioSession = audioSession
        super.init()
        callViewController.preferredContentSize = self.contentSize
        callViewController.onAppear = { [weak self] in self?.attachContentToCallView() }
    }

    deinit {
        frameTimer?.invalidate()
    }

    func prepare(on host: UIView) throws {
        guard controller == nil else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { throw VisynError.pipUnavailable }
        self.host = host
        // 通话形态的音频会话，否则系统不认作通话、小窗无法启动。
        try VisynAudioSession.activate(audioSession)
        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: host, contentViewController: callViewController)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        self.controller = controller
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.resumePendingStart() }
        }
        attachContentToHost()
    }

    func start() {
        guard controller != nil else { onError?(VisynError.pipUnavailable); return }
        guard !isActive else { return }
        startFrameTimer()
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        resumePendingStart()
    }

    @objc private func resumePendingStart() {
        guard !isActive, UIApplication.shared.applicationState == .active,
              controller?.isPictureInPicturePossible == true else { return }
        controller?.startPictureInPicture()
    }

    func stop() {
        frameTimer?.invalidate()
        frameTimer = nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        if isActive { controller?.stopPictureInPicture() }
        attachContentToHost()
    }

    /// 更新内容尺寸：同时改内容视图的尺寸与小窗的 `preferredContentSize`。
    /// 这条路能真正影响小窗大小，不再只是宽高比。
    func setContentSize(_ size: CGSize) throws {
        let size = try VisynPictureInPictureSize.validated(size)
        guard size != contentSize else { return }
        contentSize = size
        callViewController.preferredContentSize = size
        layoutContent()
    }

    // MARK: - 内容视图的落位

    /// 小窗未出现时内容留在宿主视图里，App 内联显示的就是它。
    private func attachContentToHost() {
        guard let host, content.superview !== host else {
            layoutContent()
            return
        }
        content.removeFromSuperview()
        content.frame = host.bounds
        host.addSubview(content)
        layoutContent()
    }

    /// 小窗出现时把内容移进通话控制器的视图，系统直接合成真实视图层次。
    private func attachContentToCallView() {
        guard !isHostingInCallView else { return }
        content.removeFromSuperview()
        if content.superview !== callViewController.view {
            content.frame = callViewController.view.bounds
            content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            callViewController.view.addSubview(content)
        }
        layoutContent()
    }

    private func layoutContent() {
        let container = content.superview
        content.frame = container?.bounds ?? CGRect(origin: .zero, size: contentSize)
        content.setNeedsLayout()
        content.layoutIfNeeded()
    }

    /// 小窗内不保留播放控件，动图靠定时器逐帧选图；
    /// 视频通话路线由系统按屏幕刷新率合成，这里的定时器只负责推进 GIF 与模型层更新。
    private func startFrameTimer() {
        guard frameTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / Double(framesPerSecond), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let timestamp = Date().timeIntervalSinceReferenceDate
                VisynPictureInPicturePresenter.prepareFrame(in: self.content, at: timestamp)
            }
        }
        frameTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onChange?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        stop()
        onChange?(false)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        stop()
        onRouteUnavailable?(error)
        onError?(error)
        onChange?(false)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(host?.window != nil)
    }
}
