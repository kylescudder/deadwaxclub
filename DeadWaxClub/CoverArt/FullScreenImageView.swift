import SwiftUI

/// Full-screen image viewer with Photos-app-style behaviour. Uses iOS 17's
/// native `ScrollView` paging (UIScrollView under the hood, so swipe physics
/// match the system) for horizontal navigation, plus a `simultaneousGesture`
/// for vertical drag-to-dismiss. No `TabView`, no `DragGesture`-based pager —
/// both produced janky transitions when composed with each other.
struct FullScreenImageView: View {
    let urls: [URL]
    @State private var scrolledID: Int?
    @State private var dragY: CGFloat = 0
    @State private var anyZoomed: Bool = false
    @Environment(\.dismiss) private var dismiss

    init(urls: [URL], initialIndex: Int) {
        self.urls = urls
        let clamped = max(0, min(initialIndex, urls.count - 1))
        self._scrolledID = State(initialValue: clamped)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { offset, url in
                            ZoomablePhoto(
                                url: url,
                                isCurrent: scrolledID == offset,
                                onZoomChanged: { zoomed in
                                    if scrolledID == offset { anyZoomed = zoomed }
                                }
                            )
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(offset)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrolledID)
                .scrollIndicators(.hidden)
                .scrollDisabled(anyZoomed)
                .offset(y: dragY)
                .opacity(fadeOpacity)
                .simultaneousGesture(verticalDismissGesture)

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    if urls.count > 1 {
                        thumbnailStrip
                    }
                }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
    }

    // MARK: - Vertical dismiss

    private var verticalDismissGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard !anyZoomed else { return }
                // Only respond when vertical clearly dominates, so paging swipes
                // (which usually have a small vertical wobble) don't drag the
                // image down spuriously.
                if abs(value.translation.height) > abs(value.translation.width) * 1.5 {
                    dragY = value.translation.height
                }
            }
            .onEnded { value in
                guard !anyZoomed else { return }
                let isVerticalDominant = abs(value.translation.height)
                    > abs(value.translation.width) * 1.5
                if isVerticalDominant && abs(value.translation.height) > 120 {
                    dismiss()
                } else {
                    withAnimation(.spring()) { dragY = 0 }
                }
            }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .padding()
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.5), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { offset, url in
                        thumbnail(url: url, isSelected: offset == scrolledID)
                            .id(offset)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    scrolledID = offset
                                }
                            }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }
            .onChange(of: scrolledID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private func thumbnail(url: URL, isSelected: Bool) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .empty:
                Color.white.opacity(0.05)
            case .failure:
                ZStack {
                    Color.white.opacity(0.05)
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.caption)
                }
            @unknown default:
                Color.white.opacity(0.05)
            }
        }
        .frame(width: isSelected ? 64 : 44, height: isSelected ? 64 : 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.2),
                              lineWidth: isSelected ? 2 : 1)
        )
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }

    private var fadeOpacity: Double {
        let progress: Double = Double(abs(dragY)) / 400.0
        return max(0.5, 1.0 - progress)
    }
}

/// One image inside the pager. Pinch + double-tap zoom. Reports zoom-state
/// to the parent so the parent's ScrollView paging can be disabled while the
/// user is exploring a zoomed image.
private struct ZoomablePhoto: View {
    let url: URL
    let isCurrent: Bool
    let onZoomChanged: (Bool) -> Void

    @State private var scale: CGFloat = 1.0
    @GestureState private var pinch: CGFloat = 1.0

    var body: some View {
        AsyncImage(url: url, transaction: .init(animation: .easeInOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale * pinch)
                    .gesture(
                        MagnificationGesture()
                            .updating($pinch) { current, state, _ in state = current }
                            .onEnded { final in
                                scale = clamp(scale * final, 1, 4)
                                onZoomChanged(scale > 1.01)
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scale = scale > 1.01 ? 1.0 : 2.0
                        }
                        onZoomChanged(scale > 1.01)
                    }
            case .empty:
                ProgressView().tint(.white)
            case .failure:
                offlineCard
            @unknown default:
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Reset zoom whenever this slide is no longer the current page —
        // matches Photos-app behaviour.
        .onChange(of: isCurrent) { _, nowCurrent in
            if !nowCurrent && scale > 1.01 {
                scale = 1.0
                onZoomChanged(false)
            }
        }
    }

    private var offlineCard: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.7))
            Text("Image needs an internet connection")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func clamp(_ v: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        min(max(v, a), b)
    }
}

/// Wrapper so `.fullScreenCover(item:)` can carry the urls + initial index.
struct PresentedImage: Identifiable {
    let id = UUID()
    let urls: [URL]
    let initialIndex: Int
}
