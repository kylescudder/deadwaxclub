import Foundation

/// User-facing preferences persisted via `@AppStorage`. Centralised here so
/// the AppStorage keys + locale-driven defaults stay in one place.
enum Preferences {
    static let currencyKey = "settings.currency"

    /// The currency code the user most recently chose (or the locale's
    /// default on first launch). Always returns a non-empty ISO 4217 code.
    static var currency: String {
        let stored = UserDefaults.standard.string(forKey: currencyKey) ?? ""
        if !stored.isEmpty { return stored }
        return localeCurrency
    }

    /// Best-guess from the device's region setting. Falls back to GBP if iOS
    /// can't resolve one (rare — happens in some test/CI environments).
    static var localeCurrency: String {
        Locale.current.currency?.identifier ?? "GBP"
    }

    /// The full ISO 4217 list iOS knows about, sorted with a curated short-list
    /// of common currencies pinned to the top so the picker isn't 150 items
    /// of scrolling for the 99% case.
    static var pickableCurrencies: [String] {
        let pinned = ["GBP", "USD", "EUR", "JPY", "CAD", "AUD", "CHF", "NZD"]
        let pinnedSet = Set(pinned)
        let rest = Locale.commonISOCurrencyCodes
            .filter { !pinnedSet.contains($0) }
            .sorted()
        return pinned + rest
    }

    /// Localised name + symbol for a given currency code, e.g. "GBP — £".
    static func displayName(for code: String) -> String {
        let symbol = Locale.current.localizedString(forCurrencyCode: code) ?? code
        return "\(code) — \(symbol)"
    }
}
