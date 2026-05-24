import SwiftUI

struct ConfettiBurst: View {
    let trigger: Int
    @State private var isActive = false
    @State private var isVisible = false

    private let pieces: [ConfettiPiece] = (0..<34).map { index in
        ConfettiPiece(index: index)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(pieces) { piece in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(piece.color)
                        .frame(width: piece.size.width, height: piece.size.height)
                        .rotationEffect(.degrees(isActive ? piece.rotation : 0))
                        .offset(
                            x: isActive ? piece.xTravel(in: proxy.size.width) : 0,
                            y: isActive ? piece.yTravel(in: proxy.size.height) : -40
                        )
                        .opacity(isVisible ? (isActive ? 0 : 1) : 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .onChange(of: trigger) { _, _ in
            guard trigger > 0 else { return }
            isActive = false
            isVisible = true
            withAnimation(.easeOut(duration: 0.9)) {
                isActive = true
            }
            Task {
                try? await Task.sleep(for: .seconds(0.95))
                isVisible = false
            }
        }
    }
}

private struct ConfettiPiece: Identifiable {
    let id: Int
    let color: Color
    let size: CGSize
    let rotation: Double
    private let xFactor: CGFloat
    private let yFactor: CGFloat

    init(index: Int) {
        id = index
        let colors: [Color] = [
            Theme.Colors.accent,
            .pink,
            .yellow,
            .green,
            .orange,
            .blue,
        ]
        color = colors[index % colors.count]
        size = CGSize(width: index.isMultiple(of: 3) ? 6 : 5, height: index.isMultiple(of: 2) ? 12 : 8)
        rotation = Double((index * 47) % 360)
        xFactor = CGFloat((index % 11) - 5) / 5.0
        yFactor = CGFloat(70 + ((index * 23) % 120)) / 100.0
    }

    func xTravel(in width: CGFloat) -> CGFloat {
        xFactor * min(width * 0.42, 170)
    }

    func yTravel(in height: CGFloat) -> CGFloat {
        min(height * 0.52, 360) * yFactor
    }
}
