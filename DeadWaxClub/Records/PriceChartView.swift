import SwiftUI
import Charts

struct PriceChartView: View {
    let entries: [PriceEntry]

    var body: some View {
        if entries.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.Colors.surfaceElevated)
                Text("No prices logged yet")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        } else {
            Chart(entries) { entry in
                let price = (entry.priceMajor as NSDecimalNumber).doubleValue
                LineMark(
                    x: .value("Date", entry.scannedAt),
                    y: .value("Price", price)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Theme.Colors.accent)

                PointMark(
                    x: .value("Date", entry.scannedAt),
                    y: .value("Price", price)
                )
                .foregroundStyle(Theme.Colors.accent)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let n = value.as(Double.self) {
                            Text(currencyLabel(n))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4))
            }
        }
    }

    private func currencyLabel(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = entries.first?.currency ?? "GBP"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
