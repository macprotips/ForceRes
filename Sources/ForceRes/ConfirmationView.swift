import SwiftUI

/// Contents of the floating "Keep these display settings?" panel.
struct ConfirmationView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.confirmationSpacing) {
            Text("Keep these display settings?")
                .font(.headline)
            Text(model.pendingConfirmation?.description ?? "")
                .font(.body)
            Text("Reverting in \(model.secondsRemaining) s")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Revert") { model.revertPending() }
                    .keyboardShortcut(.cancelAction)
                Button("Keep") { model.keepPending() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(PanelMetrics.confirmationPadding)
        .frame(minWidth: PanelMetrics.confirmationMinWidth)
    }
}
