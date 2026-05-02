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
        ],
        indexes: [
            Index(name: "price_entries_record",
                  columns: [IndexedColumn.ascending("record_id"),
                            IndexedColumn.descending("scanned_at")]),
        ]
    )

    static let schema = Schema(tables: [profiles, records, priceEntries])
}
