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
    private let pip: VisynPictureInPicturePresenter
    private var sessionID: UUID?
    private var lastFrameID: UUID?
    private var timer: Timer?
    private var picker: RPSystemBroadcastPickerView?

    /// Frame rate must be within 1...30. The default preserves the low-cost text-only refresh rate.
    public init(configuration: VisynConfiguration, pictureInPictureContent: UIView,
                pictureInPictureContentSize: CGSize = VisynPictureInPictureSize.landscape,
                pictureInPictureFramesPerSecond: Int = 2) throws {
        self.configuration = configuration
        pip = try VisynPictureInPicturePresenter(content: pictureInPictureContent,
                                                contentSize: pictureInPictureContentSize,
                                                framesPerSecond: pictureInPictureFramesPerSecond)
        channel = try VisynWormholeChannel(configuration: configuration)
    }

    deinit {
        timer?.invalidate()
        channel.stopListening()
    }

    public func prepare(on host: UIView) {
        guard timer == nil else { return }
        pip.onChange = { [weak self] active in self?.onPictureInPictureChange?(active) }
        pip.onError = { [weak self] error in self?.onError?(error) }
        do { try pip.prepare(on: host) } catch { onError?(error) }
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
