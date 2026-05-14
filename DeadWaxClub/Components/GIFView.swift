import SwiftUI
import UIKit
import ImageIO

/// Loads an animated GIF from the app bundle and plays it on a UIImageView,
/// wrapped as a SwiftUI view. Returns nil if the resource can't be found —
/// callers decide what to render as a fallback.
///
/// Expected resource layout: drop the gif into `DeadWaxClub/Resources/` (e.g.
/// `loading.gif`) so xcodegen picks it up via the existing resources path in
/// project.yml; `Bundle.main.url(forResource:withExtension:)` will then find
/// it without any further wiring.
struct GIFView: UIViewRepresentable {
    let name: String
    var contentMode: UIView.ContentMode = .scaleAspectFit

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = contentMode
        view.image = GIFView.animatedImage(named: name)
        view.startAnimating()
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        // If the asset changed (rare), reload.
        if uiView.image == nil {
            uiView.image = GIFView.animatedImage(named: name)
            uiView.startAnimating()
        }
    }

    /// True iff the gif exists in the bundle. Callers can use this to decide
    /// whether to render `GIFView` or fall back to something else.
    static func exists(named name: String) -> Bool {
        Bundle.main.url(forResource: name, withExtension: "gif") != nil
    }

    private static func animatedImage(named name: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gif"),
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let frameCount = CGImageSourceGetCount(source)
        var frames: [UIImage] = []
        var totalDuration: TimeInterval = 0
        for index in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: cgImage))
            totalDuration += GIFView.frameDuration(at: index, source: source)
        }
        guard !frames.isEmpty else { return nil }
        if totalDuration <= 0 {
            // Defensive: ~10fps if metadata is missing/zero.
            totalDuration = Double(frames.count) * 0.1
        }
        return UIImage.animatedImage(with: frames, duration: totalDuration)
    }

    private static func frameDuration(at index: Int, source: CGImageSource) -> TimeInterval {
        let cfProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
        guard let properties = cfProperties as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        // Unclamped is the source-of-truth value; the clamped version mirrors
        // the legacy ~100ms minimum browsers used to apply.
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        return unclamped ?? clamped ?? 0.1
    }
}
