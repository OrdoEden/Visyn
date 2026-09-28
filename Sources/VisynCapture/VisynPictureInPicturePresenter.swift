import AVKit
import UIKit
import VisynTransport

/// Opt-in updates to the model layer before each PiP frame is rasterized.
/// Select GIF frames using the monotonic timestamp; UIKit/Core Animation playback is not captured.
/// Called on the content view and every descendant that conforms, parents before children.
@MainActor
public protocol VisynPictureInPictureFrameRendering: AnyObject {
    func preparePictureInPictureFrame(at timestamp: TimeInterval)
}

/// Sends the caller's view to PiP as video frames, without accessing private windows.
@MainActor
final class VisynPictureInPicturePresenter: NSObject, VisynPictureInPicturePresenting,
                                            AVPictureInPictureControllerDelegate,
                                            AVPictureInPictureSampleBufferPlaybackDelegate {
    var onChange: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?
    private let layer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private let content: UIView
    private weak var host: UIView?
    private var possibleObservation: NSKeyValueObservation?
    private var wantsStart = false
    private var isStarting = false
    private var frameTimer: Timer?
    private let framesPerSecond: Int
    private let audioSession: VisynPictureInPictureAudioSession
    private(set) var contentSize: CGSize

    var isActive: Bool { controller?.isPictureInPictureActive == true }

    init(content: UIView, contentSize: CGSize = VisynPictureInPictureSize.landscape,
         framesPerSecond: Int = 2,
         audioSession: VisynPictureInPictureAudioSession = .playback) throws {
        guard (1...30).contains(framesPerSecond) else { throw VisynError.invalidConfiguration }
        self.content = content
        self.contentSize = try VisynPictureInPictureSize.validated(contentSize)
        self.framesPerSecond = framesPerSecond
        self.audioSession = audioSession
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(resumePendingStart),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        frameTimer?.invalidate()
    }

    func prepare(on host: UIView) throws {
        guard controller == nil else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { throw VisynError.pipUnavailable }
        self.host = host
        try VisynAudioSession.activate(audioSession)
        layer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        layer.videoGravity = .resizeAspect
        host.layer.insertSublayer(layer, at: 0)
        var timebase: CMTimebase?
        try Self.check(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                                      sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase))
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
            layer.controlTimebase = timebase
        }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        self.controller = controller
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.resumePendingStart() }
        }
        try renderFrame()
    }

    func start() {
        guard controller != nil else { onError?(VisynError.pipUnavailable); return }
        guard !isActive, !isStarting else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try renderFrame()
        } catch { onError?(error); return }
        wantsStart = true
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        if frameTimer == nil {
            let timer = Timer(timeInterval: 1 / Double(framesPerSecond), repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    do { try self.renderFrame() }
                    catch { self.stop(); self.onError?(error) }
                }
            }
            frameTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        controller?.invalidatePlaybackState()
        resumePendingStart()
    }

    @objc private func resumePendingStart() {
        guard wantsStart, !isStarting, !isActive,
              UIApplication.shared.applicationState == .active,
              controller?.isPictureInPicturePossible == true else { return }
        isStarting = true
        controller?.startPictureInPicture()
    }

    func stop() {
        wantsStart = false
        frameTimer?.invalidate()
        frameTimer = nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        if isActive { controller?.stopPictureInPicture() }
        // If stop arrived during the start animation, didStart will finish stopping it.
    }

    func setContentSize(_ size: CGSize) throws {
        let size = try VisynPictureInPictureSize.validated(size)
        guard size != contentSize else { return }
        if controller != nil {
            let previousBounds = content.bounds
            let frame: CMSampleBuffer
            do {
                frame = try Self.makeFrame(from: content, size: size, framesPerSecond: framesPerSecond)
            } catch {
                content.bounds = previousBounds
                content.setNeedsLayout()
                throw error
            }
            // Discard queued frames with the old aspect ratio, preserving the displayed image.
            layer.flush()
            layer.enqueue(frame)
        }
        contentSize = size
    }

    private func renderFrame() throws {
        if layer.status == .failed { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return }
        layer.enqueue(try Self.makeFrame(from: content, size: contentSize, framesPerSecond: framesPerSecond))
    }

    /// CPU rendering also works while PiP keeps the app running in the background.
    static func makeFrame(from content: UIView, size: CGSize = VisynPictureInPictureSize.landscape,
                          framesPerSecond: Int = 2) throws -> CMSampleBuffer {
        guard (1...30).contains(framesPerSecond) else { throw VisynError.invalidConfiguration }
        let size = try VisynPictureInPictureSize.validated(size)
        let timestamp = CMClockGetTime(CMClockGetHostTimeClock())
        let scale = renderScale(for: size)
        let width = Int(size.width * scale), height = Int(size.height * scale)
        content.bounds = CGRect(origin: .zero, size: size)
        applyContentScale(scale, to: content)
        content.setNeedsLayout()
        content.layoutIfNeeded()
        prepareFrame(in: content, at: CMTimeGetSeconds(timestamp))
        content.layoutIfNeeded()
        var pixelBuffer: CVPixelBuffer?
        try check(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                     [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer))
        guard let pixelBuffer else { throw VisynError.pipUnavailable }
        try check(CVPixelBufferLockBaseAddress(pixelBuffer, []))
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { throw VisynError.pipUnavailable }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        content.layer.render(in: context)
        var format: CMVideoFormatDescription?
        try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                               imageBuffer: pixelBuffer, formatDescriptionOut: &format))
        guard let format else { throw VisynError.pipUnavailable }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(framesPerSecond)),
                                        presentationTimeStamp: timestamp,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                          formatDescription: format, sampleTiming: &timing,
                                                          sampleBufferOut: &sample))
        guard let sample else { throw VisynError.pipUnavailable }
        return sample
    }

    /// Long side of the rendered frame, in pixels. The system scales the video up to the PiP
    /// window, so small layout sizes (e.g. the 90 × 220 portrait preset) need a higher density
    /// to stay sharp. Matches the 1280 × 1280 buffer bound in `VisynPictureInPictureSize`.
    static let targetPixelLength: CGFloat = 1280

    /// Integer pixels-per-point for a content size: at least 2, at most 6.
    static func renderScale(for size: CGSize) -> CGFloat {
        let longSide = max(size.width, size.height, 1)
        return min(6, max(2, (targetPixelLength / longSide).rounded(.down)))
    }

    /// Offscreen views are not in a window, so their backing stores default to the screen
    /// (or 1×) scale; text would then be upsampled into the larger buffer and look blurry.
    /// Only touches layers whose scale differs, so steady-state frames do not force redraws.
    static func applyContentScale(_ scale: CGFloat, to view: UIView) {
        if view.contentScaleFactor != scale { view.contentScaleFactor = scale }
        for sublayer in view.layer.sublayers ?? [] where !(sublayer.delegate is UIView) {
            applyContentScale(scale, to: sublayer)
        }
        for subview in view.subviews { applyContentScale(scale, to: subview) }
    }

    private static func applyContentScale(_ scale: CGFloat, to layer: CALayer) {
        if layer.contentsScale != scale {
            layer.contentsScale = scale
            layer.setNeedsDisplay()
        }
        for sublayer in layer.sublayers ?? [] where !(sublayer.delegate is UIView) {
            applyContentScale(scale, to: sublayer)
        }
    }

    /// 供两条路线共用：递归通知子视图按时间戳选动图帧。
    static func prepareFrame(in view: UIView, at timestamp: TimeInterval) {
        (view as? VisynPictureInPictureFrameRendering)?.preparePictureInPictureFrame(at: timestamp)
        for subview in view.subviews where !subview.isHidden {
            prepareFrame(in: subview, at: timestamp)
        }
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStarting = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStarting = false
        guard wantsStart else { pictureInPictureController.stopPictureInPicture(); return }
        wantsStart = false
        onChange?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        stop()
        isStarting = false
        onChange?(false)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        stop()
        isStarting = false
        onChange?(false)
        onError?(error)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(host?.window != nil)
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        // The content is a live view, with no independent pause/seek timeline.
        pictureInPictureController.invalidatePlaybackState()
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
