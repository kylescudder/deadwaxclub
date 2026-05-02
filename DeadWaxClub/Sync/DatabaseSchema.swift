import Foundation
import PowerSync

/// Local SQLite schema mirrored from Postgres. Column types intentionally
/// permissive (PowerSync-Swift normalizes to TEXT/INTEGER/REAL).
enum DatabaseSchema {
    static let profiles = Table(
        name: "profiles",
        columns: [
            Column.text("display_name"),
            Column.text("created_at"),
            Column.text("updated_at"),
        ]
    )

    static let records = Table(
        name: "records",
        columns: [
            Column.text("owner_id"),
            Column.text("status"),
            Column.text("title"),
            Column.text("artist"),
            Column.integer("year"),
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
            Index(name: "records_owner_status",
                  columns: [IndexedColumn.ascending("owner_id"), IndexedColumn.ascending("status")]),
            Index(name: "records_barcode",
                  columns: [IndexedColumn.ascending("barcode")]),
        ]
    )

    static let priceEntries = Table(
        name: "price_entries",
        columns: [
            Column.text("record_id"),
            Column.text("owner_id"),
            Column.integer("price_cents"),
            Column.text("currency"),
            Column.text("shop_name"),
            Column.text("scanned_at"),
            Column.text("created_at"),
            Column.integer("previous_min_cents"),
            Column.integer("is_new_low"),
        ],
        indexes: [
            Index(name: "price_entries_record",
                  columns: [IndexedColumn.ascending("record_id"),
                            IndexedColumn.descending("scanned_at")]),
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
        profiles, records, priceEntries, lists, listItems, listMembers, deviceTokens
    ])
}
