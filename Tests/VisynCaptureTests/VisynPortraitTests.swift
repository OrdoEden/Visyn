import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import VisynCapture

final class VisynPortraitTests: XCTestCase {
    func testPortraitLayoutFollowsContentOrientation() {
        let landscape = VisynPortraitLayout(size: CGSize(width: 414, height: 80))
        XCTAssertFalse(landscape.isPortrait)
        XCTAssertEqual(landscape.imageFrame, CGRect(x: 0, y: 0, width: 80, height: 80))
        XCTAssertEqual(landscape.fadeEndPoint, CGPoint(x: 1, y: 0))

        let portrait = VisynPortraitLayout(size: CGSize(width: 80, height: 480))
        XCTAssertTrue(portrait.isPortrait)
        XCTAssertEqual(portrait.imageFrame, CGRect(x: 0, y: 0, width: 80, height: 80))
        XCTAssertEqual(portrait.fadeEndPoint, CGPoint(x: 0, y: 1))

        let square = VisynPortraitLayout(size: CGSize(width: 100, height: 100))
        XCTAssertEqual(square.imageFrame.width, 40)
    }

    private func gif(colors: [UIColor], delay: Double) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString,
                                                                         colors.count, nil))
        for color in colors {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
            CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testAnimatedImageSelectsFramesByTimestampAndLoops() throws {
        let animation = try XCTUnwrap(VisynAnimatedImage(data: gif(colors: [.red, .green, .blue], delay: 0.1)))
        XCTAssertEqual(animation.frames.count, 3)
        XCTAssertEqual(animation.duration, 0.3, accuracy: 0.001)
        XCTAssertTrue(animation.frame(at: 0.05) === animation.frames[0])
        XCTAssertTrue(animation.frame(at: 0.15) === animation.frames[1])
        XCTAssertTrue(animation.frame(at: 0.35) === animation.frames[0])
        XCTAssertTrue(animation.frame(at: .nan) === animation.frames[0])
        XCTAssertNil(VisynAnimatedImage(data: Data([0, 1, 2])))
    }

    @MainActor
    func testFramePreparationReachesNestedAnimatedViews() throws {
        let animation = try XCTUnwrap(VisynAnimatedImage(data: gif(colors: [.red, .green], delay: 0.5)))
        let root = UIView()
        let container = UIView()
        let animated = VisynAnimatedImageView()
        animated.animation = animation
        animated.playsAnimation = true
        container.addSubview(animated)
        root.addSubview(container)
        VisynPictureInPicturePresenter.prepareFrame(in: root, at: 0.75)
        let expected = UIAccessibility.isReduceMotionEnabled ? animation.frames[0] : animation.frames[1]
        XCTAssertTrue(animated.image === expected)

        animated.playsAnimation = false
        VisynPictureInPicturePresenter.prepareFrame(in: root, at: 0.75)
        XCTAssertTrue(animated.image === animation.frames[0])
    }

    @MainActor
    func testPortraitViewFallsBackToPlaceholderAndAppliesTint() {
        let view = VisynPortraitView(frame: CGRect(x: 0, y: 0, width: 414, height: 80))
        let tint = UIColor(red: 0.9, green: 0.8, blue: 0.7, alpha: 1)
        view.setPortrait(image: nil, tint: tint)
        XCTAssertEqual(view.backgroundColor, tint)
        XCTAssertEqual(view.tint, tint)
    }
}
