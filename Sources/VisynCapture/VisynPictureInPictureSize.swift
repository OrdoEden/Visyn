import Foundation
import CoreGraphics

/// Content layout presets and optional local persistence. The host app owns the sizing UI.
///
/// iOS only uses the content's aspect ratio to shape the PiP window; the window's on-screen size
/// is chosen by the system (and the user's pinch). Width and height here set the layout points
/// the content is drawn at, so 90 × 220 and 180 × 440 produce the same window shape.
public enum VisynPictureInPictureSize {
    public struct Preset: Equatable, Sendable {
        public let title: String
        public let size: CGSize
    }

    /// The original horizontal strip, also used when no size is provided.
    public static let landscape = CGSize(width: 414, height: 80)
    /// Vertical 9 : 22, a little slimmer than the iPhone screen (9 : 19.5) so the PiP window
    /// stays narrower at the same system size.
    public static let portrait = CGSize(width: 90, height: 220)
    /// Square 1 : 1.
    public static let rectangle = CGSize(width: 80, height: 80)
    /// Presets in display order for host sizing UIs.
    public static let presets = [Preset(title: "横屏", size: landscape),
                                 Preset(title: "竖屏", size: portrait)]
    public static let userDefaultsKey = "Visyn.pictureInPictureContentSize"

    /// Returns nil when no valid saved size exists; callers choose their fallback preset.
    public static func load(from defaults: UserDefaults = .standard,
                            forKey key: String = userDefaultsKey) -> CGSize? {
        guard let values = defaults.dictionary(forKey: key) as? [String: Double],
              let width = values["width"], let height = values["height"] else { return nil }
        return try? validated(CGSize(width: CGFloat(width), height: CGFloat(height)))
    }

    /// Saves a validated, rounded size. Invalid input leaves the existing preference untouched.
    /// Call after successfully applying the size to VisynCaptureController.
    public static func save(_ size: CGSize, to defaults: UserDefaults = .standard,
                            forKey key: String = userDefaultsKey) throws {
        let size = try validated(size)
        defaults.set(["width": Double(size.width), "height": Double(size.height)], forKey: key)
    }

    static func validated(_ size: CGSize) throws -> CGSize {
        // Bound CPU rendering and allocation to at most a 1280 × 1280 BGRA buffer.
        guard size.width.isFinite, size.height.isFinite,
              (1...640).contains(size.width), (1...640).contains(size.height) else {
            throw NSError(domain: "VisynPictureInPicture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "画中画内容宽高须为 1～640 点之间的有限数值。"])
        }
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }
}
