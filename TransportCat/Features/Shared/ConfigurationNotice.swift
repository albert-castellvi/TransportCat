import SwiftUI

/// Notice shown when the build lacks TMB credentials.
struct ConfigurationNotice: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
