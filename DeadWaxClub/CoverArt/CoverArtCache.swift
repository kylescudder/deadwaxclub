import Foundation
import UIKit

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
        let local = Self.localFile(for: record.id)
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

        let localFile = Self.localFile(for: record.id)
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
                let path = "\(record.ownerID)/\(record.id).jpg"
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
            path: path,
            file: bytes,
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
}
