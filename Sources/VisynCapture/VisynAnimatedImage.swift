import ImageIO
import UIKit

/// 按视频时钟选帧的动图。PiP 以离屏光栅化出帧，UIImageView 自带动画不会被捕获，
/// 因此由 `VisynAnimatedImageView` 在每个视频帧前显式选择图片。
public final class VisynAnimatedImage {
    public let frames: [UIImage]
    private let ends: [TimeInterval]
    public let duration: TimeInterval

    /// 解码 GIF 等多帧图片；最多保留 maximumFrames 帧。无法解码时返回 nil。
    public init?(data: Data, maximumFrames: Int = 120) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var frames: [UIImage] = [], ends: [TimeInterval] = [], total: TimeInterval = 0
        for index in 0..<min(CGImageSourceGetCount(source), max(1, maximumFrames)) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.07
            total += delay.isFinite ? max(0.02, delay) : 0.07
            frames.append(UIImage(cgImage: image))
            ends.append(total)
        }
        guard !frames.isEmpty else { return nil }
        self.frames = frames
        self.ends = ends
        duration = total
    }

    public convenience init?(url: URL, maximumFrames: Int = 120) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data, maximumFrames: maximumFrames)
    }

    /// 单调时间戳对应的帧，按总时长循环。
    public func frame(at timestamp: TimeInterval) -> UIImage {
        guard frames.count > 1, duration > 0, timestamp.isFinite else { return frames[0] }
        var position = timestamp.truncatingRemainder(dividingBy: duration)
        if position < 0 { position += duration }
        return frames[ends.firstIndex(where: { position < $0 }) ?? 0]
    }
}

/// 在 PiP 中播放 `VisynAnimatedImage` 的图片视图。系统开启"减弱动态效果"时停在首帧。
@MainActor
public final class VisynAnimatedImageView: UIImageView, VisynPictureInPictureFrameRendering {
    public var animation: VisynAnimatedImage? {
        didSet { image = animation?.frames.first ?? fallbackImage }
    }
    /// 没有动图时显示的静态图。
    public var fallbackImage: UIImage? {
        didSet { if animation == nil { image = fallbackImage } }
    }
    /// 为 false 时固定显示首帧。
    public var playsAnimation = false {
        didSet { if !playsAnimation { image = animation?.frames.first ?? fallbackImage } }
    }

    public func preparePictureInPictureFrame(at timestamp: TimeInterval) {
        guard let animation else { return }
        image = playsAnimation && !UIAccessibility.isReduceMotionEnabled
            ? animation.frame(at: timestamp) : animation.frames[0]
    }
}
