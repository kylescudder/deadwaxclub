import Foundation
import Security

/// Deadwax Club's values for the shared push adapters (`PushManager`,
/// `PushRegistration`, `AuthClient+PushIdentity`).
enum PushAppConfiguration {
    /// The Keychain item that already holds Deadwax's gateway installation ID
    /// (no service attribute, as written by `Utilities/Keychain.swift`).
    /// Changing it would give every device a new installation.
    static let installationIDKeychainService: String? = nil
    static let installationIDKeychainAccessibility = kSecAttrAccessibleAfterFirstUnlock as String

    static let fallbackBundleID = "com.deadwaxclub.app"

    /// Pushes from notify-inbox carry a `kind` discriminator. A collection
    /// invite opens the Collection; a push with only a `record_id` is a price
    /// alert and opens the record.
    static func route(for userInfo: [AnyHashable: Any]) -> PushRoute? {
        if userInfo["kind"] as? String == "collection_invite",
           let collectionID = userInfo["collection_id"] as? String {
            return PushRoute(name: .openCollection, userInfo: ["collection_id": collectionID])
        }
        if let recordID = userInfo["record_id"] as? String {
            return PushRoute(name: .openRecord, userInfo: ["record_id": recordID])
        }
        return nil
    }
}

extension Notification.Name {
    static let openRecord = Notification.Name("deadwaxclub.openRecord")
}
