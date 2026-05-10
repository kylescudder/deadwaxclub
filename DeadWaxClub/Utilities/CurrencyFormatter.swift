import Foundation

enum CurrencyFormatter {
    /// A `NumberFormatter` pre-configured for the given ISO 4217 currency code.
    /// Returned formatter can be tweaked further (e.g. `maximumFractionDigits = 0`
    /// for chart-axis labels) before calling `.string(from:)`.
    static func formatter(code: String) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        return f
    }

    /// Format an integer cents value as a localised currency string.
    /// `formatCents(1499, code: "GBP") -> "£14.99"`.
    static func formatCents(_ cents: Int, code: String) -> String {
        formatter(code: code).string(from: NSDecimalNumber(value: Double(cents) / 100.0))
            ?? "\(cents)"
    }

    /// Format a major-unit `Double` as a localised currency string.
    /// `formatMajor(15.0, code: "GBP") -> "£15.00"`.
    static func formatMajor(_ value: Double, code: String) -> String {
        formatter(code: code).string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Format a major-unit `Decimal` as a localised currency string.
    static func formatMajor(_ value: Decimal, code: String) -> String {
        formatter(code: code).string(from: value as NSDecimalNumber)
            ?? "\(value) \(code)"
    }
}
