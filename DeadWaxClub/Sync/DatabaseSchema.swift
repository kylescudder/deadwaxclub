import Foundation
import PowerSync

/// Local SQLite schema mirrored from Postgres. Column types intentionally
/// permissive (PowerSync-Swift normalizes to TEXT/INTEGER/REAL).
enum DatabaseSchema {
    /// Classification is explicit so replicated snapshots cannot accidentally
    /// enter the CRUD upload queue.
    static let writableTableNames = Set([
        "profiles", "records", "albums", "record_pressings", "price_entries",
        "record_images", "collections", "notifications", "lists", "list_items",
    ])
    static let readOnlyTableNames = Set([
        "collection_members", "collection_pending_invites", "list_members",
        "pending_invites", "record_creation_quotas", "iap_entitlements",
    ])
    static let localOnlyTableNames = Set(["pending_record_creations"])

    static let profiles = Table(
        name: "profiles",
        columns: [
            Column.text("display_name"),
            Column.text("primary_collection_id"),
            Column.integer("is_premium_account"),
            Column.text("created_at"),
            Column.text("updated_at"),
        ]
    )

    static let records = Table(
        name: "records",
        columns: [
            Column.text("record_pressing_id"),
            Column.text("collection_id"),
            Column.text("created_by"),
            Column.text("status"),
            Column.text("notes"),
            Column.text("created_at"),
            Column.text("updated_at"),
            Column.text("deleted_at"),
        ],
        indexes: [
            Index(name: "records_collection_status",
                  columns: [IndexedColumn.ascending("collection_id"), IndexedColumn.ascending("status")]),
            Index(name: "records_creator_updated",
                  columns: [IndexedColumn.ascending("created_by"), IndexedColumn.descending("updated_at")]),
        ]
    )

    static let albums = Table(
        name: "albums",
        columns: [
            Column.text("dedupe_key"),
            Column.text("title"),
            Column.text("artist"),
            Column.integer("album_year"),
            Column.text("created_at"),
            Column.text("updated_at"),
        ],
        indexes: [
            Index(name: "albums_dedupe",
                  columns: [IndexedColumn.ascending("dedupe_key")]),
        ]
    )

    static let recordPressings = Table(
        name: "record_pressings",
        columns: [
            Column.text("album_id"),
            Column.text("dedupe_key"),
            Column.integer("year"),
            Column.text("colourway"),
            Column.text("cover_art_source_url"),
            Column.text("cover_art_storage_path"),
            Column.integer("discogs_release_id"),
            Column.text("barcode"),
            Column.integer("estimated_price_cents"),
            Column.text("estimated_price_currency"),
            Column.text("estimated_price_updated_at"),
            Column.text("created_at"),
            Column.text("updated_at"),
        ],
        indexes: [
            Index(name: "record_pressings_dedupe",
                  columns: [IndexedColumn.ascending("dedupe_key")]),
            Index(name: "record_pressings_album",
                  columns: [IndexedColumn.ascending("album_id")]),
        ]
    )

    static let priceEntries = Table(
        name: "price_entries",
        columns: [
            Column.text("record_id"),
            Column.text("owner_id"),
            Column.text("collection_id"),
            Column.integer("price_cents"),
            Column.text("currency"),
            Column.text("shop_name"),
            Column.text("scanned_at"),
            Column.text("created_at"),
            Column.text("updated_at"),
            Column.text("deleted_at"),
            Column.integer("previous_min_cents"),
            Column.integer("is_new_low"),
        ],
        indexes: [
            Index(name: "price_entries_record",
                  columns: [IndexedColumn.ascending("record_id"),
                            IndexedColumn.descending("scanned_at")]),
        ]
    )

    static let collections = Table(
        name: "collections",
        columns: [
            Column.text("name"),
            Column.text("created_by"),
            Column.text("created_at"),
            Column.text("updated_at"),
            Column.text("deleted_at"),
        ]
    )

    static let collectionMembers = Table(
        name: "collection_members",
        columns: [
            Column.text("collection_id"),
            Column.text("user_id"),
            Column.text("role"),
            Column.text("invited_by"),
            Column.text("joined_at"),
        ],
        indexes: [
            Index(name: "collection_members_collection",
                  columns: [IndexedColumn.ascending("collection_id")]),
            Index(name: "collection_members_user",
                  columns: [IndexedColumn.ascending("user_id")]),
        ]
    )

    static let collectionPendingInvites = Table(
        name: "collection_pending_invites",
        columns: [
            Column.text("collection_id"),
            Column.text("email"),
            Column.text("role"),
            Column.text("invited_by"),
            Column.text("created_at"),
            Column.text("accepted_at"),
        ],
        indexes: [
            Index(name: "collection_pending_invites_collection",
                  columns: [IndexedColumn.ascending("collection_id")]),
        ]
    )

    static let recordImages = Table(
        name: "record_images",
        columns: [
            Column.text("record_id"),
            Column.text("collection_id"),
            Column.text("kind"),
            Column.integer("position"),
            Column.text("source_url"),
            Column.text("storage_path"),
            Column.text("uploaded_by"),
            Column.text("created_at"),
        ],
        indexes: [
            Index(name: "record_images_record",
                  columns: [IndexedColumn.ascending("record_id"),
                            IndexedColumn.ascending("position")]),
        ]
    )

    static let notifications = Table(
        name: "notifications",
        columns: [
            Column.text("user_id"),
            Column.text("kind"),
            Column.text("title"),
            Column.text("body"),
            Column.text("payload"),
            Column.text("read_at"),
            Column.text("created_at"),
        ],
        indexes: [
            Index(name: "notifications_user_created",
                  columns: [IndexedColumn.ascending("user_id"),
                            IndexedColumn.descending("created_at")]),
        ]
    )

    static let lists = Table(
        name: "lists",
        columns: [
            Column.text("owner_id"),
            Column.text("name"),
            Column.text("description"),
            Column.text("share_mode"),
            Column.text("share_token"),
            Column.text("cover_record_id"),
            Column.text("created_at"),
            Column.text("updated_at"),
            Column.text("deleted_at"),
        ]
    )

    static let listItems = Table(
        name: "list_items",
        columns: [
            Column.text("list_id"),
            Column.text("record_id"),
            Column.text("added_by"),
            Column.integer("position"),
            Column.text("created_at"),
        ],
        indexes: [
            Index(name: "list_items_list",
                  columns: [IndexedColumn.ascending("list_id"),
                            IndexedColumn.ascending("position")]),
        ]
    )

    static let listMembers = Table(
        name: "list_members",
        columns: [
            Column.text("list_id"),
            Column.text("user_id"),
            Column.text("role"),
            Column.text("invited_by"),
            Column.text("joined_at"),
        ]
    )

    static let pendingInvites = Table(
        name: "pending_invites",
        columns: [
            Column.text("list_id"),
            Column.text("email"),
            Column.text("role"),
            Column.text("invited_by"),
            Column.text("created_at"),
            Column.text("accepted_at"),
        ],
        indexes: [
            Index(name: "pending_invites_list",
                  columns: [IndexedColumn.ascending("list_id")]),
        ]
    )

    /// Read-only server snapshots. They are streamed to the device but never
    /// written through PowerSync's CRUD queue.
    static let recordCreationQuotas = Table(
        name: "record_creation_quotas",
        columns: [
            Column.integer("lifetime_record_count"),
            Column.text("updated_at"),
        ]
    )

    static let iapEntitlements = Table(
        name: "iap_entitlements",
        columns: [
            Column.text("bundle_id"),
            Column.text("product_id"),
            Column.text("transaction_id"),
            Column.text("original_transaction_id"),
            Column.text("status"),
            Column.text("expires_at"),
            Column.text("revoked_at"),
            Column.text("environment"),
            Column.text("signed_at"),
            Column.text("verified_at"),
            Column.text("verification_source"),
            Column.text("updated_at"),
        ]
    )

    /// Device-only reservations for record creates waiting in the CRUD queue.
    static let pendingRecordCreations = Table(
        name: "pending_record_creations",
        columns: [
            Column.text("user_id"),
            Column.integer("expected_lifetime_count"),
            Column.text("state"),
            Column.text("created_at"),
        ],
        indexes: [Index(name: "pending_record_creations_user", columns: [IndexedColumn.ascending("user_id")])],
        localOnly: true
    )

    static let schema = Schema(tables: [
        profiles, records, albums, recordPressings, priceEntries, recordImages,
        collections, collectionMembers, collectionPendingInvites,
        notifications,
        lists, listItems, listMembers, pendingInvites,
        recordCreationQuotas, iapEntitlements, pendingRecordCreations,
    ])
}
