import SwiftUI

/// Compact banner listing active disruptions for the visible line.
struct AlertBanner: View {
    let alerts: [ServiceAlert]
    let lineColor: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Afectacions actives", image: "icon-alert")
                .font(.footnote.bold())
            ForEach(alerts.prefix(2)) { alert in
                Text(summary(of: alert))
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(hex: lineColor).opacity(0.85))
    }

    /// Cleaned copy: the feeds ship HTML in the alert text (S15).
    private func summary(of alert: ServiceAlert) -> String {
        if let text = AlertText.cleaned(alert.text) { return text }
        if !alert.stationNames.isEmpty {
            return alert.stationNames.prefix(3).joined(separator: ", ")
        }
        return "Servei afectat"
    }
}
