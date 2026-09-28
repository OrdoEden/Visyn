import AVFoundation
import UIKit
import XCTest
@testable import VisynCapture

final class VisynPictureInPictureTests: XCTestCase {
    @MainActor
    private final class AnimatedContent: UIView, VisynPictureInPictureFrameRendering {
        var preparedAt: TimeInterval?
        var preparedSize: CGSize?

        func preparePictureInPictureFrame(at timestamp: TimeInterval) {
            preparedAt = timestamp
            preparedSize = bounds.size
            backgroundColor = .red
        }
    }

    @MainActor
    func testAnimationPreparationIsCapturedWithMatchingTimingAndRejectsInvalidFrameRate() throws {
        let view = AnimatedContent()
        view.backgroundColor = .blue
        let size = CGSize(width: 40, height: 60)
        let frame = try VisynPictureInPicturePresenter.makeFrame(from: view, size: size, framesPerSecond: 15)
        XCTAssertEqual(view.preparedSize, size)
        XCTAssertEqual(try XCTUnwrap(view.preparedAt), CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(frame)),
                       accuracy: 0.000001)
        XCTAssertEqual(CMSampleBufferGetDuration(frame), CMTime(value: 1, timescale: 15))
        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(frame))
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes, count: 4)), [0, 0, 255, 255])
        for rate in [0, -1, 31, Int.max] {
            XCTAssertThrowsError(try VisynPictureInPicturePresenter(content: view, framesPerSecond: rate))
            XCTAssertThrowsError(try VisynPictureInPicturePresenter.makeFrame(from: view, framesPerSecond: rate))
        }
    }

    @MainActor
    func testLiveViewFramesHaveValidTimingAndUprightUpdatedPixels() throws {
        let view = UIView()
        view.backgroundColor = .white
        let top = UIView(frame: CGRect(x: 0, y: 0, width: 414, height: 40))
        top.backgroundColor = .red
        view.addSubview(top)
        let stripSize = CGSize(width: 414, height: 80)
        let first = try VisynPictureInPicturePresenter.makeFrame(from: view, size: stripSize)
        XCTAssertTrue(CMSampleBufferIsValid(first))
        XCTAssertTrue(CMSampleBufferDataIsReady(first))
        XCTAssertTrue(CMSampleBufferGetPresentationTimeStamp(first).isNumeric)
        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(first))
        XCTAssertEqual(CVPixelBufferGetWidth(pixels), 1242)
        XCTAssertEqual(CVPixelBufferGetHeight(pixels), 240)
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes + row * 20 + 40, count: 4)), [0, 0, 255, 255])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes + row * 140 + 40, count: 4)), [255, 255, 255, 255])
        top.backgroundColor = .blue
        let second = try VisynPictureInPicturePresenter.makeFrame(from: view, size: stripSize)
        XCTAssertGreaterThanOrEqual(CMSampleBufferGetPresentationTimeStamp(second), CMSampleBufferGetPresentationTimeStamp(first))
        let updated = try XCTUnwrap(CMSampleBufferGetImageBuffer(second))
        CVPixelBufferLockBaseAddress(updated, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(updated, .readOnly) }
        let updatedBytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(updated)).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: updatedBytes + CVPixelBufferGetBytesPerRow(updated) * 20 + 40, count: 4)), [255, 0, 0, 255])
    }

    @MainActor
    func testDefaultAndResizedFramesMatchContentLayoutAndVideoFormat() throws {
        let view = UIView()
        let defaultFrame = try VisynPictureInPicturePresenter.makeFrame(from: view)
        let defaultPixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(defaultFrame))
        XCTAssertEqual(view.bounds.size, CGSize(width: 414, height: 80))
        XCTAssertEqual(CVPixelBufferGetWidth(defaultPixels), 1242)
        XCTAssertEqual(CVPixelBufferGetHeight(defaultPixels), 240)
        // Render density fills ~1280 px on the long side so small layouts stay sharp.
        XCTAssertEqual(VisynPictureInPicturePresenter.renderScale(for: VisynPictureInPictureSize.landscape), 3)
        XCTAssertEqual(VisynPictureInPicturePresenter.renderScale(for: VisynPictureInPictureSize.portrait), 5)
        XCTAssertEqual(VisynPictureInPicturePresenter.renderScale(for: CGSize(width: 40, height: 60)), 6)
        XCTAssertEqual(VisynPictureInPicturePresenter.renderScale(for: CGSize(width: 1, height: 640)), 2)

        // Reuse one content view to catch stale geometry when the user changes the shape.
        XCTAssertEqual(VisynPictureInPictureSize.landscape, CGSize(width: 414, height: 80))
        XCTAssertEqual(VisynPictureInPictureSize.portrait, CGSize(width: 90, height: 220))
        XCTAssertEqual(VisynPictureInPictureSize.presets.map(\.size),
                       [VisynPictureInPictureSize.landscape, VisynPictureInPictureSize.portrait])
        XCTAssertEqual(VisynPictureInPictureSize.rectangle, CGSize(width: 80, height: 80))
        for size in [VisynPictureInPictureSize.portrait, VisynPictureInPictureSize.rectangle,
                     CGSize(width: 301.4, height: 199.6), CGSize(width: 1, height: 640)] {
            let sample = try VisynPictureInPicturePresenter.makeFrame(from: view, size: size)
            let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            XCTAssertEqual(view.bounds.size, CGSize(width: size.width.rounded(), height: size.height.rounded()))
            let scale = VisynPictureInPicturePresenter.renderScale(for: view.bounds.size)
            XCTAssertEqual(CVPixelBufferGetWidth(pixels), Int(size.width.rounded() * scale))
            XCTAssertEqual(CVPixelBufferGetHeight(pixels), Int(size.height.rounded() * scale))
            XCTAssertEqual(Int(dimensions.width), CVPixelBufferGetWidth(pixels))
            XCTAssertEqual(Int(dimensions.height), CVPixelBufferGetHeight(pixels))
            XCTAssertTrue(CMSampleBufferIsValid(sample))
        }
    }

    @MainActor
    func testInvalidSizesAreRejectedWithoutChangingAcceptedSizeOrView() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let presenter = try VisynPictureInPicturePresenter(content: view)
        XCTAssertEqual(presenter.contentSize, VisynPictureInPictureSize.landscape)
        try presenter.setContentSize(CGSize(width: 240.2, height: 319.7))
        XCTAssertEqual(presenter.contentSize, CGSize(width: 240, height: 320))
        let originalBounds = view.bounds

        let invalidDimensions: [CGFloat] = [0, -1, 0.4, 641, .infinity, .nan]
        for dimension in invalidDimensions {
            for size in [CGSize(width: dimension, height: 240), CGSize(width: 320, height: dimension)] {
                XCTAssertThrowsError(try presenter.setContentSize(size))
                XCTAssertThrowsError(try VisynPictureInPicturePresenter(content: view, contentSize: size))
                XCTAssertThrowsError(try VisynPictureInPicturePresenter.makeFrame(from: view, size: size))
                XCTAssertEqual(presenter.contentSize, CGSize(width: 240, height: 320))
                XCTAssertEqual(view.bounds, originalBounds)
            }
        }
    }

    func testSizePreferencesRoundTripAndRejectInvalidValues() throws {
        let suite = "VisynPictureInPictureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(VisynPictureInPictureSize.load(from: defaults))
        try VisynPictureInPictureSize.save(VisynPictureInPictureSize.portrait, to: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(VisynPictureInPictureSize.load(from: reopened), CGSize(width: 90, height: 220))

        try VisynPictureInPictureSize.save(CGSize(width: 123.4, height: 60.7), to: defaults, forKey: "custom")
        XCTAssertEqual(VisynPictureInPictureSize.load(from: defaults, forKey: "custom"), CGSize(width: 123, height: 61))
        XCTAssertEqual(VisynPictureInPictureSize.load(from: defaults), VisynPictureInPictureSize.portrait)
        XCTAssertThrowsError(try VisynPictureInPictureSize.save(CGSize(width: 0, height: 60), to: defaults))
        XCTAssertEqual(VisynPictureInPictureSize.load(from: defaults), VisynPictureInPictureSize.portrait)

        let invalidValues: [Any] = ["invalid", ["width": 80], ["width": "invalid", "height": "60"],
                                    ["width": 0, "height": 60], ["width": 80, "height": 641]]
        for value in invalidValues {
            defaults.set(value, forKey: VisynPictureInPictureSize.userDefaultsKey)
            XCTAssertNil(VisynPictureInPictureSize.load(from: defaults))
        }
    }

    /// 路线只保存名字；没保存过与存了无法识别的值都当作未设置，由接入方决定默认值。
    func testRoutePreferenceRoundTripAndRejectsUnknownValues() throws {
        let suite = "VisynPictureInPictureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(VisynPictureInPictureRoute.load(from: defaults))

        VisynPictureInPictureRoute.videoCall.save(to: defaults)
        XCTAssertEqual(VisynPictureInPictureRoute.load(from: defaults), .videoCall)
        VisynPictureInPictureRoute.sampleBuffer.save(to: defaults)
        XCTAssertEqual(VisynPictureInPictureRoute.load(from: defaults), .sampleBuffer)

        defaults.set("unknownRoute", forKey: VisynPictureInPictureRoute.userDefaultsKey)
        XCTAssertNil(VisynPictureInPictureRoute.load(from: defaults))
        XCTAssertEqual(VisynPictureInPictureRoute.presets.map(\.route), [.sampleBuffer, .videoCall])
    }
}
