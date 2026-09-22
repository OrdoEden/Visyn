import AVKit
import UIKit
import VisynTransport

/// Sends the caller's view to PiP as video frames, without accessing private windows.
@MainActor
final class VisynPictureInPicturePresenter: NSObject, AVPictureInPictureControllerDelegate,
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

    var isActive: Bool { controller?.isPictureInPictureActive == true }

    init(content: UIView) {
        self.content = content
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
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try audio.setActive(true)
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
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
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

    private func renderFrame() throws {
        if layer.status == .failed { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return }
        layer.enqueue(try Self.makeFrame(from: content))
    }

    /// CPU rendering also works while PiP keeps the app running in the background.
    static func makeFrame(from content: UIView) throws -> CMSampleBuffer {
        let size = CGSize(width: 414, height: 80)
        let width = 828, height = 160
        content.bounds = CGRect(origin: .zero, size: size)
        content.setNeedsLayout()
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
        context.scaleBy(x: 2, y: -2)
        content.layer.render(in: context)
        var format: CMVideoFormatDescription?
        try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                               imageBuffer: pixelBuffer, formatDescriptionOut: &format))
        guard let format else { throw VisynError.pipUnavailable }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 2),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                          formatDescription: format, sampleTiming: &timing,
                                                          sampleBufferOut: &sample))
        guard let sample else { throw VisynError.pipUnavailable }
        return sample
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
