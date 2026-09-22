import VisynCapture
import UIKit

final class VisynDemoViewController: UIViewController {
    private var capture: VisynCaptureController?
    private let statusLabel = UILabel()
    private let frameLabel = UILabel()
    private let recordButton = UIButton(configuration: .filled())
    private let pipButton = UIButton(configuration: .filled())
    private var receivedFrames = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        buildView()
        do {
            let capture = try VisynCaptureController(configuration: .load(), pictureInPictureContent: makePiPContent())
            self.capture = capture
            capture.onStateChange = { [weak self] state in
                guard let self else { return }
                self.recordButton.configuration?.title = state == .stopped ? "开始录屏" : "停止录屏"
                switch state {
                case .broadcasting: self.statusLabel.text = "正在采集屏幕"
                case .paused: self.statusLabel.text = "录屏已暂停"
                case .stopped:
                    self.statusLabel.text = "录屏已停止"
                    self.receivedFrames = 0
                    self.frameLabel.text = "等待屏幕数据"
                }
            }
            capture.onFrame = { [weak self] frame in
                guard let self else { return }
                self.receivedFrames += 1
                self.frameLabel.text = "已收到 \(self.receivedFrames) 帧 · \(frame.width) × \(frame.height)"
                // frame.jpegData is the app's entry point for future local OCR/analysis.
            }
            capture.onPictureInPictureChange = { [weak self] active in
                self?.pipButton.configuration?.title = active ? "关闭画中画" : "开启画中画"
            }
            capture.onError = { [weak self] error in self?.statusLabel.text = error.localizedDescription }
            capture.prepare(on: view)
        } catch {
            statusLabel.text = error.localizedDescription
            recordButton.isEnabled = false
            pipButton.isEnabled = false
        }
    }

    private func buildView() {
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Visyn Demo"
        title.font = .preferredFont(forTextStyle: .largeTitle)
        statusLabel.text = "准备就绪"
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel
        frameLabel.text = "等待屏幕数据"
        frameLabel.numberOfLines = 0
        frameLabel.font = .preferredFont(forTextStyle: .footnote)
        recordButton.configuration?.title = "开始录屏"
        recordButton.configuration?.baseBackgroundColor = .systemRed
        recordButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.capture?.showBroadcastPicker(on: self.view)
        }, for: .touchUpInside)
        pipButton.configuration?.title = "开启画中画"
        pipButton.addAction(UIAction { [weak self] _ in self?.capture?.togglePictureInPicture() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, statusLabel, frameLabel, recordButton, pipButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            recordButton.heightAnchor.constraint(equalToConstant: 52),
            pipButton.heightAnchor.constraint(equalToConstant: 52)
        ])
    }

    private func makePiPContent() -> UIView {
        let content = UIView()
        content.backgroundColor = .white
        let label = UILabel()
        label.text = "测试中"
        label.font = .systemFont(ofSize: 22, weight: .medium)
        label.textColor = .black
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        return content
    }
}
