import SwiftUI

/// Service status: active disruptions across the whole metro network.
struct AlertsScreen: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let message = app.missingCredentialsMessage {
                    ConfigurationNotice(message: message)
                        .listRowBackground(Color.clear)
                } else if let error = app.alertsErrorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if app.alerts.isEmpty {
                    Label("Sense afectacions registrades", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    ForEach(app.alerts) { alert in
                        AlertRow(alert: alert)
                    }
                }
            }
            .navigationTitle("Avisos")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await app.refreshAlerts()
            }
            .task {
                await app.refreshAlerts()
            }
        }
    }
}

private struct AlertRow: View {
    let alert: ServiceAlert

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(alert.lineCodes, id: \.self) { code in
                    if let line = MetroLine.line(forCode: code) {
                        Text(line.displayName)
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color(hex: line.colorHex)))
                    }
                }
                Spacer()
                if let end = alert.endDate {
                    Text(end, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let text = alert.text, !text.isEmpty {
                Text(text)
                    .font(.footnote)
            }
            if !alert.stationNames.isEmpty {
                Text(alert.stationNames.prefix(6).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
