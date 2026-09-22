import VisynTransport
import CoreImage
import ImageIO
import ReplayKit

/// The extension target only needs an empty subclass and its NSExtensionPrincipalClass entry.
open class VisynBroadcastSampleHandler: RPBroadcastSampleHandler {
    private var sender: VisynBroadcastSender?

    open override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        do {
            let sender = try VisynBroadcastSender(configuration: .load())
            sender.onError = { [weak self] error in
                DispatchQueue.main.async { self?.finishBroadcastWithError(error) }
            }
            self.sender = sender
            try sender.start()
        } catch { finishBroadcastWithError(error) }
    }

    open override func broadcastPaused() { sender?.setState(.paused) }
    open override func broadcastResumed() { sender?.setState(.broadcasting) }
    open override func broadcastFinished() {
        sender?.stop()
        sender = nil
    }

    open override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        sender?.process(sampleBuffer)
    }
}

private final class VisynBroadcastSender {
    var onError: ((Error) -> Void)?
    private let channel: VisynWormholeChannel
    private let queue = DispatchQueue(label: "Visyn.frames", qos: .utility)
    private let slot = DispatchSemaphore(value: 1)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let sessionID = UUID()
    private var state = VisynBroadcastState.stopped
    private var heartbeat: DispatchSourceTimer?
    private var lastFrameTime = -Double.infinity
    private var frameWrittenAt: Date?

    init(configuration: VisynConfiguration) throws {
        channel = try VisynWormholeChannel(configuration: configuration)
    }

    deinit { heartbeat?.cancel() }

    func start() throws {
        try queue.sync {
            channel.clear(.frame)
            state = .broadcasting
            try publishStatus()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                do {
                    try self.publishStatus()
                    // A suspended host must not leave a screenshot indefinitely in the App Group.
                    if let date = self.frameWrittenAt, Date().timeIntervalSince(date) > 2 {
                        self.channel.clear(.frame)
                        self.frameWrittenAt = nil
                    }
                } catch { self.fail(error) }
            }
            heartbeat = timer
            timer.resume()
        }
    }

    func setState(_ newState: VisynBroadcastState) {
        queue.sync {
            state = newState
            channel.clear(.frame)
            frameWrittenAt = nil
            lastFrameTime = -Double.infinity
            do { try publishStatus() } catch { fail(error) }
        }
    }

    func stop() {
        queue.sync {
            state = .stopped
            heartbeat?.cancel()
            heartbeat = nil
            channel.clear(.frame)
            do { try publishStatus() } catch { onError?(error) }
        }
    }

    func process(_ sample: CMSampleBuffer) {
        // Bound retained buffers to one; never enqueue the full ReplayKit frame rate.
        guard slot.wait(timeout: .now()) == .success else { return }
        queue.async { [self] in
            defer { slot.signal() }
            guard state == .broadcasting else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastFrameTime >= 0.3 else { return }
            lastFrameTime = now
            autoreleasepool {
                do {
                    // One outstanding frame; the receiver deletes it after consumption.
                    if let previous = try channel.read(VisynCapturedFrame.self, from: .frame),
                       Date().timeIntervalSince(previous.capturedAt) <= 2 { return }
                    channel.clear(.frame)
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
                    var image = CIImage(cvPixelBuffer: buffer)
                    if let orientation = CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString,
                                                         attachmentModeOut: nil) as? NSNumber {
                        image = image.oriented(forExifOrientation: orientation.int32Value)
                    }
                    image = image.transformed(by: CGAffineTransform(
                        translationX: -image.extent.minX, y: -image.extent.minY
                    ))
                    let scale = min(1, 1280 / max(image.extent.width, image.extent.height))
                    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                          let data = context.jpegRepresentation(of: image, colorSpace: colorSpace,
                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]) else {
                        throw VisynError.invalidMessage
                    }
                    let frame = VisynCapturedFrame(sessionID: sessionID, width: Int(image.extent.width),
                                              height: Int(image.extent.height), jpegData: data)
                    try frame.validate()
                    try channel.send(frame, to: .frame)
                    frameWrittenAt = frame.capturedAt
                } catch { fail(error) }
            }
        }
    }

    private func publishStatus() throws {
        try channel.send(VisynBroadcastStatus(sessionID: sessionID, state: state), to: .status)
    }

    private func fail(_ error: Error) {
        state = .stopped
        heartbeat?.cancel()
        heartbeat = nil
        channel.clear(.frame)
        try? publishStatus()
        onError?(error)
    }
}
