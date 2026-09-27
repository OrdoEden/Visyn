import VisynCapture
import UIKit

final class VisynDemoViewController: UIViewController {
    private var capture: VisynCaptureController?
    private let statusLabel = UILabel()
    private let frameLabel = UILabel()
    private let recordButton = UIButton(configuration: .filled())
    private let pipButton = UIButton(configuration: .filled())
    private let sizePresets = UISegmentedControl(items: VisynPictureInPictureSize.presets.map(\.title))
    private let sizeLabel = UILabel()
    private let widthField = UITextField()
    private let heightField = UITextField()
    private let applySizeButton = UIButton(configuration: .filled())
    private let presetSizes = VisynPictureInPictureSize.presets.map(\.size)
    private var contentSize = VisynPictureInPictureSize.load() ?? VisynPictureInPictureSize.landscape
    private var receivedFrames = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        buildView()
        do {
            let capture = try VisynCaptureController(
                configuration: .load(),
                pictureInPictureContent: makePiPContent(),
                pictureInPictureContentSize: contentSize
            )
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
            sizePresets.isEnabled = false
            widthField.isEnabled = false
            heightField.isEnabled = false
            applySizeButton.isEnabled = false
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
        sizePresets.selectedSegmentIndex = 0
        sizePresets.addAction(UIAction { [weak self] _ in
            guard let self, self.presetSizes.indices.contains(self.sizePresets.selectedSegmentIndex) else { return }
            self.applyContentSize(self.presetSizes[self.sizePresets.selectedSegmentIndex])
        }, for: .valueChanged)
        sizeLabel.font = .preferredFont(forTextStyle: .subheadline)
        sizeLabel.numberOfLines = 0
        let instructions = UILabel()
        instructions.font = .preferredFont(forTextStyle: .footnote)
        instructions.textColor = .secondaryLabel
        instructions.numberOfLines = 0
        instructions.text = "预设：横屏/长条 414 × 80、竖屏 80 × 60、矩形 80 × 80。也可输入 1～640 点的宽高，成功应用后自动保存。\n\n这里设置内容尺寸，系统小窗的实际大小和缩放范围由 iOS 控制。"
        let keyboardToolbar = UIToolbar()
        keyboardToolbar.items = [
            UIBarButtonItem(title: "应用", style: .plain, target: self, action: #selector(applyEnteredSize)),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(dismissKeyboard))
        ]
        keyboardToolbar.sizeToFit()
        for (field, name) in [(widthField, "宽度（点）"), (heightField, "高度（点）")] {
            field.borderStyle = .roundedRect
            field.keyboardType = .decimalPad
            field.placeholder = name
            field.accessibilityLabel = name
            field.inputAccessoryView = keyboardToolbar
        }
        let dimensions = UIStackView(arrangedSubviews: [widthField, heightField])
        dimensions.spacing = 12
        dimensions.distribution = .fillEqually
        applySizeButton.configuration?.title = "应用宽高"
        applySizeButton.addAction(UIAction { [weak self] _ in self?.applyEnteredSize() }, for: .touchUpInside)
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)
        let stack = UIStackView(arrangedSubviews: [
            title, statusLabel, frameLabel, recordButton, pipButton,
            sizePresets, sizeLabel, dimensions, applySizeButton, instructions
        ])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -48),
            recordButton.heightAnchor.constraint(equalToConstant: 52),
            pipButton.heightAnchor.constraint(equalToConstant: 52),
            sizePresets.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            dimensions.heightAnchor.constraint(equalToConstant: 44),
            applySizeButton.heightAnchor.constraint(equalToConstant: 52)
        ])
        updateSizeDisplay()
    }

    private func updateSizeDisplay() {
        sizeLabel.text = "内容尺寸：\(Int(contentSize.width)) × \(Int(contentSize.height)) 点"
        sizePresets.selectedSegmentIndex = presetSizes.firstIndex(of: contentSize) ?? UISegmentedControl.noSegment
        widthField.text = String(Int(contentSize.width))
        heightField.text = String(Int(contentSize.height))
    }

    private func applyContentSize(_ size: CGSize) {
        guard let capture else { return }
        view.endEditing(true)
        do {
            try capture.setPictureInPictureContentSize(size)
            try VisynPictureInPictureSize.save(capture.pictureInPictureContentSize)
            statusLabel.text = "内容尺寸已应用并保存"
        } catch {
            statusLabel.text = "调整内容尺寸失败：\(error.localizedDescription)"
        }
        contentSize = capture.pictureInPictureContentSize
        updateSizeDisplay()
    }

    @objc private func applyEnteredSize() {
        func dimension(from field: UITextField) -> Double? {
            let text = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
            return Double(text)
        }
        guard let width = dimension(from: widthField), let height = dimension(from: heightField) else {
            statusLabel.text = "请输入有效的宽度和高度（1～640 点）。"
            updateSizeDisplay()
            view.endEditing(true)
            return
        }
        applyContentSize(CGSize(width: CGFloat(width), height: CGFloat(height)))
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func makePiPContent() -> UIView {
        let content = UIView()
        content.backgroundColor = .white
        let label = UILabel()
        label.text = "测试中"
        label.font = .systemFont(ofSize: 22, weight: .medium)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.1
        label.textColor = .black
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.9)
        ])
        return content
    }
}
