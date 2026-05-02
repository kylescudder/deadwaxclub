import SwiftUI

/// Renders a record's cover art using the best available source:
/// local Caches file → Supabase Storage URL → Discogs URL → placeholder.
/// Triggers caching to local + Supabase as a side effect on first appearance.
struct CoverArtImage: View {
    let record: VinylRecord

    @EnvironmentObject private var services: AppServices
    @State private var renderedURL: URL?

    var body: some View {
        Group {
            if let url = renderedURL {
                AsyncImage(url: url, transaction: .init(animation: .easeInOut(duration: 0.2))) { phase in
                    switch phase {
                    case .empty:
                        placeholder
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipped()
        .task(id: record.id) {
            renderedURL = services.coverArt.displayURL(for: record)
            await services.coverArt.cacheIfNeeded(record: record) { newPath in
                Task { @MainActor in
                    await services.records.updateStoragePath(recordID: record.id, storagePath: newPath)
                    // After caching, switch to the local file URL.
                    renderedURL = CoverArtCache.localFile(for: record.id)
                }
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Theme.Colors.surfaceElevated
            Image(systemName: "opticaldisc")
                .font(.system(size: 24))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
    }
}
