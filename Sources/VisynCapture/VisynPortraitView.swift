import UIKit

/// 立绘层几何：横向内容把立绘放在左侧、向右淡出；竖向内容放在顶部、向下淡出。
/// 纯值计算，宿主可在非主线程复用（例如按立绘位置推算 OCR 遮挡区）。
public struct VisynPortraitLayout: Sendable, Equatable {
    public let size: CGSize

    public init(size: CGSize) { self.size = size }

    public var isPortrait: Bool { size.height > size.width }

    /// 立绘图片的位置：竖向取宽度与 42% 高度的较小值，横向取高度与 40% 宽度的较小值。
    public var imageFrame: CGRect {
        let side = isPortrait ? min(size.width, size.height * 0.42) : min(size.height, size.width * 0.4)
        return CGRect(x: 0, y: 0, width: max(0, side), height: max(0, side))
    }

    /// 淡出方向（单位坐标，适用于 CAGradientLayer）。
    public var fadeEndPoint: CGPoint { isPortrait ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0) }
}

/// 通用立绘视图：主题底色 + 沿阅读方向淡出的立绘图片。宿主把文案视图叠在它上面。
/// 不含任何业务文字；图片与主题色由宿主传入。
@MainActor
public final class VisynPortraitView: UIView {
    private let imageView = UIImageView()
    private let fadeMask = CAGradientLayer()
    private var hasImage = false

    /// 无立绘时显示的占位图与颜色。
    public var placeholderImage: UIImage? = UIImage(systemName: "person.crop.square.fill") {
        didSet { if !hasImage { imageView.image = placeholderImage } }
    }
    public var placeholderTintColor: UIColor = UIColor(red: 0.58, green: 0.70, blue: 0.64, alpha: 1) {
        didSet { imageView.tintColor = placeholderTintColor }
    }
    /// 图片保持不透明的比例（0...1），之后淡出到底色。
    public var solidFraction: CGFloat = 0.65 {
        didSet { fadeMask.locations = [0, NSNumber(value: Double(min(max(solidFraction, 0), 1))), 1] }
    }
    /// 宿主指定的立绘位置（本视图坐标）；nil 时使用 `VisynPortraitLayout` 的默认几何。
    /// 当宿主还要按立绘位置推算其他内容（例如 OCR 遮挡锚点）时，传入同一份几何保持一致。
    public var imageFrame: CGRect? {
        didSet { if imageFrame != oldValue { setNeedsLayout() } }
    }
    public private(set) var tint: UIColor = UIColor(red: 0.88, green: 0.94, blue: 0.90, alpha: 1)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        backgroundColor = tint
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.tintColor = placeholderTintColor
        imageView.image = placeholderImage
        fadeMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        fadeMask.locations = [0, NSNumber(value: Double(solidFraction)), 1]
        fadeMask.startPoint = .zero
        imageView.layer.mask = fadeMask
        addSubview(imageView)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 设置立绘与主题色；image 为 nil 时回到占位图。
    public func setPortrait(image: UIImage?, tint: UIColor) {
        hasImage = image != nil
        imageView.image = image ?? placeholderImage
        self.tint = tint
        backgroundColor = tint
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let layout = VisynPortraitLayout(size: bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.frame = imageFrame ?? layout.imageFrame
        fadeMask.frame = imageView.bounds
        fadeMask.endPoint = layout.fadeEndPoint
        CATransaction.commit()
    }
}
