import SwiftUI
import UIKit

struct ComputerPairingHelpView: View {
    @State private var hasCopied = false

    private let command = "python3 Scripts/setup-device.py"

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(text("setup.commandTitle")).font(.headline)
                Text(text("setup.commandRequirements"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(text("setup.commandLocation"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(verbatim: command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("computerPairingCommand")
                Button {
                    // This contains no identity or credentials. Allow Universal
                    // Clipboard so the user can paste the command on their Mac.
                    UIPasteboard.general.string = command
                    hasCopied = true
                } label: {
                    Label(text(hasCopied ? "setup.commandCopied" : "setup.copyCommand"),
                          systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("copyComputerPairingCommandButton")
                Text(text("setup.commandSelection"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(text("setup.commandImport"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(text("setup.commandClipboardHint"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: "Onboarding")
    }
}
