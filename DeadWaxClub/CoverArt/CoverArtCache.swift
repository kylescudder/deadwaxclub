import Foundation
import CryptoKit

/// Two-tier cover art cache:
/// 1. Local file at `<Caches>/covers/<recordID>.jpg` — read first, available fully offline.
/// 2. Supabase Storage `covers` bucket — populated on first sight by any device, so other
///    devices that have synced the row can pull the bytes via HTTP without hitting Discogs.
///
/// Flow on first display of a record without a local file:
///   - download bytes from `cover_art_storage_path` (if set) or `cover_art_source_url`
///   - write the bytes to local Caches
///   - if no `cover_art_storage_path` yet, upload to Supabase and report the new path back
@MainActor
final class CoverArtCache: ObservableObject {
    private let auth: AuthClient
    private let session: URLSession
    private let fileManager = FileManager.default
    private var inFlight: Set<String> = []

    init(authClient: AuthClient, session: URLSession = .shared) {
        self.auth = authClient
        self.session = session
        try? fileManager.createDirectory(at: Self.coversDir, withIntermediateDirectories: true)
    }

    nonisolated static var coversDir: URL {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cache.appendingPathComponent("covers", isDirectory: true)
    }

    /// Best display URL for a record, resolved in this order:
    ///   1. local file (file:// URL) if cached on disk
    ///   2. Supabase Storage public URL if `cover_art_storage_path` is set
    ///   3. original Discogs URL
    func displayURL(for record: VinylRecord) -> URL? {
        let local = Self.localFile(for: record.coverCacheID)
        if fileManager.fileExists(atPath: local.path) {
            return local
        }
        if let path = record.coverArtStoragePath {
            return Self.publicStorageURL(path: path)
        }
        if let s = record.coverArtSourceURL { return URL(string: s) }
        return nil
    }

    /// Downloads bytes to disk (if missing) and uploads to Supabase Storage (if missing).
    /// Calls `onStoragePathPersisted` when a new storage path is created so the caller
    /// can write it back to the local SQLite row (PowerSync will then propagate it).
    func cacheIfNeeded(record: VinylRecord, onStoragePathPersisted: @escaping (String) -> Void) async {
        guard !inFlight.contains(record.id) else { return }
        inFlight.insert(record.id)
        defer { inFlight.remove(record.id) }

        let localFile = Self.localFile(for: record.coverCacheID)
        let needsLocal = !fileManager.fileExists(atPath: localFile.path)
        let needsRemote = record.coverArtStoragePath == nil

        guard needsLocal || needsRemote else { return }

        guard let bytes = await fetchBytes(record: record) else { return }

        if needsLocal {
            do {
                try bytes.write(to: localFile, options: .atomic)
            } catch {
                Log.error(error, category: "coverart.localwrite")
            }
        }

        if needsRemote {
            do {
                let path = primaryCoverPath(for: record)
                try await uploadToSupabase(bytes: bytes, path: path)
                onStoragePathPersisted(path)
            } catch {
                Log.error(error, category: "coverart.upload")
            }
        }
    }

    private func fetchBytes(record: VinylRecord) async -> Data? {
        let url: URL? = {
            if let path = record.coverArtStoragePath {
                return Self.publicStorageURL(path: path)
            }
            return record.coverArtSourceURL.flatMap(URL.init(string:))
        }()
        guard let url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue("DeadWaxClub/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            Log.error(error, category: "coverart.download")
            return nil
        }
    }

    private func uploadToSupabase(bytes: Data, path: String) async throws {
        let storage = auth.supabase.storage.from("covers")
        _ = try await storage.upload(
            path,
            data: bytes,
            options: .init(contentType: "image/jpeg", upsert: true)
        )
    }

    nonisolated static func localFile(for recordID: String) -> URL {
        coversDir.appendingPathComponent("\(recordID).jpg")
    }

    nonisolated static func publicStorageURL(path: String) -> URL? {
        // covers is a public bucket; URL form is /storage/v1/object/public/covers/<path>
        var components = URLComponents(url: AppSecrets.supabaseURL, resolvingAgainstBaseURL: false)
        components?.path = "/storage/v1/object/public/covers/\(path)"
        return components?.url
    }

    /// Remove the on-device file (e.g. record was deleted).
    func evict(recordID: String) {
        let file = Self.localFile(for: recordID)
        try? fileManager.removeItem(at: file)
    }

    // MARK: - Carousel / record_images

    /// Best display URL for a non-primary carousel image. Storage-only — no
    /// local file caching (only the primary cover gets that for offline).
    /// Returns nil only when neither a storage_path nor source_url is set.
    nonisolated func displayURL(for image: RecordImage) -> URL? {
        if let path = image.storagePath {
            return Self.publicStorageURL(path: path)
        }
        return image.sourceURL.flatMap(URL.init(string:))
    }

    /// If the image has a source_url but no storage_path, fetch the bytes
    /// from upstream and mirror into Supabase Storage. Reports the new path
    /// so the caller can persist it on the record_images row (PowerSync
    /// replicates and other devices fetch from Storage instead of the
    /// upstream / Discogs CDN).
    func mirrorIfNeeded(
        image: RecordImage,
        onStoragePathPersisted: @escaping (String) -> Void
    ) async {
        guard image.storagePath == nil, let source = image.sourceURL else { return }
        guard !inFlight.contains(image.id) else { return }
        inFlight.insert(image.id)
        defer { inFlight.remove(image.id) }

        guard let bytes = await fetchBytes(fromURL: source) else { return }
        do {
            let path = recordImagePath(image: image)
            try await uploadToSupabase(bytes: bytes, path: path)
            onStoragePathPersisted(path)
        } catch {
            Log.error(error, category: "coverart.mirror")
        }
    }

    /// Upload user-supplied image bytes (from photo picker / camera) for a
    /// new RecordImage row. Returns the storage path the caller should write
    /// onto the row.
    func uploadUserImage(
        bytes: Data,
        collectionID: String,
        recordID: String,
        imageID: String
    ) async throws -> String {
        let path = "user/\(collectionID)/\(recordID)/\(imageID).jpg"
        try await uploadToSupabase(bytes: bytes, path: path)
        return path
    }

    private func recordImagePath(image: RecordImage) -> String {
        if let sourceURL = image.sourceURL {
            return "discogs/images/\(Self.stableHash(sourceURL)).jpg"
        }
        return "user/\(image.collectionID)/\(image.recordID)/\(image.id).jpg"
    }

    private func primaryCoverPath(for record: VinylRecord) -> String {
        if let pressingID = record.recordPressingID {
            return "pressings/\(pressingID)/primary.jpg"
        }

        if let releaseID = record.discogsReleaseID {
            return "discogs/releases/\(releaseID)/primary.jpg"
        }

        let key = [
            record.artist,
            record.title,
            record.displayYear.map(String.init),
            record.colourway,
        ]
            .compactMap { $0 }
            .joined(separator: "|")
        return "manual/\(Self.storageSlug(for: key))/primary.jpg"
    }

    private nonisolated static func stableHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func storageSlug(for value: String) -> String {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let slug = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
        return slug.isEmpty ? stableHash(value) : slug
    }

    private func fetchBytes(fromURL urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue("DeadWaxClub/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            Log.error(error, category: "coverart.download")
            return nil
        }
    }
}
