import SwiftUI

/// Contents of the floating "Keep these display settings?" panel.
struct ConfirmationView: View {
    let model: AppModel

    var body: some View {
        // The description reads "Display → setting"; show the setting first and the display under it.
        let parts = (model.pendingConfirmation?.description ?? "").components(separatedBy: " → ")
        let setting = parts.last ?? ""
        let display = parts.count > 1 ? parts[0] : nil

        VStack(alignment: .leading, spacing: PanelMetrics.confirmationSpacing) {
            HStack(alignment: .top, spacing: PanelMetrics.confirmationIconToText) {
                Image(systemName: "display")
                    .font(.system(size: PanelMetrics.confirmationIconSize, weight: .light))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: PanelMetrics.confirmationLineSpacing) {
                    Text("Keep these display settings?")
                        .font(.headline)
                    Text(setting)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if let display {
                        Text(display)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text("Reverting in \(model.secondsRemaining) s")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { model.revertPending() }
                    .keyboardShortcut(.cancelAction)
                Button("Keep") { model.keepPending() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(PanelMetrics.confirmationPadding)
        .frame(minWidth: PanelMetrics.confirmationMinWidth)
    }
}
