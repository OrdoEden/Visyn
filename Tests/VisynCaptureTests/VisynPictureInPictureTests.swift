import AVFoundation
import UIKit
import XCTest
@testable import VisynCapture

final class VisynPictureInPictureTests: XCTestCase {
    @MainActor
    func testLiveViewFramesHaveValidTimingAndUprightUpdatedPixels() throws {
        let view = UIView()
        view.backgroundColor = .white
        let top = UIView(frame: CGRect(x: 0, y: 0, width: 414, height: 40))
        top.backgroundColor = .red
        view.addSubview(top)
        let first = try VisynPictureInPicturePresenter.makeFrame(from: view)
        XCTAssertTrue(CMSampleBufferIsValid(first))
        XCTAssertTrue(CMSampleBufferDataIsReady(first))
        XCTAssertTrue(CMSampleBufferGetPresentationTimeStamp(first).isNumeric)
        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(first))
        XCTAssertEqual(CVPixelBufferGetWidth(pixels), 828)
        XCTAssertEqual(CVPixelBufferGetHeight(pixels), 160)
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes + row * 20 + 40, count: 4)), [0, 0, 255, 255])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes + row * 140 + 40, count: 4)), [255, 255, 255, 255])
        top.backgroundColor = .blue
        let second = try VisynPictureInPicturePresenter.makeFrame(from: view)
        XCTAssertGreaterThanOrEqual(CMSampleBufferGetPresentationTimeStamp(second), CMSampleBufferGetPresentationTimeStamp(first))
        let updated = try XCTUnwrap(CMSampleBufferGetImageBuffer(second))
        CVPixelBufferLockBaseAddress(updated, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(updated, .readOnly) }
        let updatedBytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(updated)).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: updatedBytes + CVPixelBufferGetBytesPerRow(updated) * 20 + 40, count: 4)), [255, 0, 0, 255])
    }
}
