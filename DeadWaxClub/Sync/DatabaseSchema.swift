import Foundation
import PowerSync

/// Local SQLite schema mirrored from Postgres. Column types intentionally
/// permissive (PowerSync-Swift normalizes to TEXT/INTEGER/REAL).
enum DatabaseSchema {
    static let profiles = Table(
        name: "profiles",
        columns: [
            Column.text("display_name"),
            Column.text("primary_collection_id"),
            Column.text("created_at"),
            Column.text("updated_at"),
        ]
    )

    static let records = Table(
        name: "records",
        columns: [
            Column.text("collection_id"),
            Column.text("status"),
            Column.text("title"),
            Column.text("artist"),
            Column.integer("year"),
            Column.integer("album_year"),
            Column.text("colourway"),
            Column.text("cover_art_source_url"),
            Column.text("cover_art_storage_path"),
            Column.integer("discogs_release_id"),
            Column.text("barcode"),
            Column.text("notes"),
            Column.integer("estimated_price_cents"),
            Column.text("estimated_price_currency"),
            Column.text("estimated_price_updated_at"),
            Column.text("created_at"),
            Column.text("updated_at"),
            Column.text("deleted_at"),
        ],
        indexes: [
            Index(name: "records_collection_status",
                  columns: [IndexedColumn.ascending("collection_id"), IndexedColumn.ascending("status")]),
            Index(name: "records_barcode",
                  columns: [IndexedColumn.ascending("barcode")]),
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

    static let deviceTokens = Table(
        name: "device_tokens",
        columns: [
            Column.text("user_id"),
            Column.text("apns_token"),
            Column.text("device_name"),
            Column.text("bundle_id"),
            Column.text("environment"),
            Column.text("created_at"),
            Column.text("updated_at"),
        ]
    )

    static let schema = Schema(tables: [
        profiles, records, priceEntries, recordImages,
        collections, collectionMembers, collectionPendingInvites,
        notifications,
        lists, listItems, listMembers, pendingInvites,
        deviceTokens,
    ])
}
