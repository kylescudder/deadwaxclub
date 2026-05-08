import SwiftUI

/// Swipable carousel of every image attached to a record. The first slide is
/// the primary cover, sourced from the existing local-file / Supabase Storage
/// cache and works fully offline. Secondary slides come from `record_images`,
/// streamed from Supabase Storage; if a slide can't load (no network and the
/// bytes haven't been mirrored yet) we render an offline-state card on that
/// slide rather than failing the whole carousel.
///
/// Tap any slide to open the image full-screen with pinch-to-zoom.
///
/// Falls back to a single CoverArtImage when no record_images rows exist for
/// the record yet — covers legacy records imported before this feature.
struct RecordImageCarousel: View {
    let record: VinylRecord

    @EnvironmentObject private var services: AppServices
    @State private var index: Int = 0
    @State private var presented: PresentedImage?

    var body: some View {
        let secondaries = secondaryImages
        Group {
            if secondaries.isEmpty {
                CoverArtImage(record: record)
                    .contentShape(Rectangle())
                    .onTapGesture { presentFullScreen(at: 0) }
            } else {
                VStack(spacing: Theme.Spacing.sm) {
                    TabView(selection: $index) {
                        CoverArtImage(record: record)
                            .contentShape(Rectangle())
                            .onTapGesture { presentFullScreen(at: 0) }
                            .tag(0)
                        ForEach(Array(secondaries.enumerated()), id: \.element.id) { offset, image in
                            SecondaryImageSlide(image: image)
                                .contentShape(Rectangle())
                                .onTapGesture { presentFullScreen(at: offset + 1) }
                                .tag(offset + 1)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .aspectRatio(1, contentMode: .fit)

                    pageIndicator(total: secondaries.count + 1)
                }
                .task(id: record.id) {
                    services.recordImages.startWatching(recordID: record.id)
                }
            }
        }
        .fullScreenCover(item: $presented) { item in
            FullScreenImageView(urls: item.urls, initialIndex: item.initialIndex)
        }
    }

    private var secondaryImages: [RecordImage] {
        // Skip position 0 — that's the primary cover, already rendered via
        // CoverArtImage off `records.cover_art_*` (with local-file caching).
        services.recordImages.images.filter { $0.position > 0 }
    }

    /// Every slide's display URL, in carousel order. Primary first, then the
    /// secondaries, dropping any slide whose URL can't be resolved (offline
    /// + unmirrored). The full-screen viewer paginates through this list.
    private var allDisplayURLs: [URL] {
        var urls: [URL] = []
        if let primary = services.coverArt.displayURL(for: record) {
            urls.append(primary)
        }
        for image in secondaryImages {
            if let url = services.coverArt.displayURL(for: image) {
                urls.append(url)
            }
        }
        return urls
    }

    private func pageIndicator(total: Int) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Theme.Colors.accent : Theme.Colors.surfaceElevated)
                    .frame(width: i == index ? 22 : 8, height: 8)
                    .animation(.easeInOut(duration: 0.2), value: index)
            }
        }
    }

    private func presentFullScreen(at index: Int) {
        let urls = allDisplayURLs
        guard !urls.isEmpty else { return }
        presented = PresentedImage(urls: urls, initialIndex: min(index, urls.count - 1))
    }
}

/// Renders a non-primary image. Streams from Supabase Storage (or upstream
/// source) — no local file cache. Shows an offline-state card if neither
/// source resolves.
private struct SecondaryImageSlide: View {
    let image: RecordImage
    @EnvironmentObject private var services: AppServices

    @State private var phaseFailed: Bool = false

    var body: some View {
        Group {
            if let url = services.coverArt.displayURL(for: image), !phaseFailed {
                AsyncImage(url: url, transaction: .init(animation: .easeInOut(duration: 0.2))) { phase in
                    switch phase {
                    case .empty:
                        loading
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        offlineCard
                    @unknown default:
                        loading
                    }
                }
            } else {
                offlineCard
            }
        }
        .clipped()
        .task(id: image.id) {
            // First sight mirrors upstream bytes into Supabase Storage so
            // every other device fetches them without hitting Discogs.
            await services.coverArt.mirrorIfNeeded(image: image) { newPath in
                Task { @MainActor in
                    await services.recordImages.updateStoragePath(
                        imageID: image.id, storagePath: newPath
                    )
                }
            }
        }
    }

    private var loading: some View {
        ZStack {
            Theme.Colors.surfaceElevated
            ProgressView()
        }
    }

    private var offlineCard: some View {
        ZStack {
            Theme.Colors.surfaceElevated
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text("Image needs an internet connection")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }
}
