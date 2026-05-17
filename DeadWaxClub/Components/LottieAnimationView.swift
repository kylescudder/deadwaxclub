import Lottie
import SwiftUI

struct LottieAnimationView: UIViewRepresentable {
    let name: String
    var loopMode: LottieLoopMode = .loop

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true

        let view = Lottie.LottieAnimationView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundBehavior = .pauseAndRestore
        view.contentMode = .scaleAspectFit
        view.loopMode = loopMode
        view.clipsToBounds = true

        if let animation = loadAnimation() {
            view.animation = animation
            view.imageProvider = BundleImageProvider(bundle: .main, searchPath: "")
            view.play()
        }

        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let animationView = uiView.subviews.first as? Lottie.LottieAnimationView else {
            return
        }

        animationView.loopMode = loopMode
        if !animationView.isAnimationPlaying {
            animationView.play()
        }
    }

    private func loadAnimation() -> LottieAnimation? {
        if let url = Bundle.main.url(forResource: name, withExtension: "json") {
            return LottieAnimation.filepath(url.path)
        }

        if let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Animations") {
            return LottieAnimation.filepath(url.path)
        }

        return LottieAnimation.named(name)
    }
}
