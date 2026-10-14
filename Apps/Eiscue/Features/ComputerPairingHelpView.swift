import SwiftUI
import UIKit

struct ComputerPairingHelpView: View {
    @State private var hasCopied = false

    static let command = """
    (
      eiscue_setup_dir="$(mktemp -d -t eiscue-setup)" || exit 1
      git clone --depth 1 https://github.com/LLLLLayer/Eiscue.git "$eiscue_setup_dir" &&
      python3 "$eiscue_setup_dir/Scripts/setup-device.py"
    )
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            step(1, "setup.stepMacTitle", "setup.stepMacDetail")
            step(2, "setup.stepPhoneTitle", "setup.stepPhoneDetail")
            VStack(alignment: .leading, spacing: 8) {
                PairingSetupStepTitle(number: 3, title: text("setup.stepRunTitle"))
                Text(text("setup.stepRunDetail")).font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(text("setup.terminalLabel")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button {
                            // Only the public command is shared through Universal Clipboard.
                            UIPasteboard.general.string = Self.command
                            hasCopied = true
                        } label: {
                            Label(text(hasCopied ? "setup.commandCopied" : "setup.copyCommand"),
                                  systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                        }
                        .font(.caption).buttonStyle(.glass).controlSize(.small)
                        .accessibilityIdentifier("copyComputerPairingCommandButton")
                    }
                    Text(verbatim: Self.command)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("computerPairingCommand")
                }
                .padding(12)
                .background(EiscueStyle.background, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func step(_ number: Int, _ title: String.LocalizationValue, _ detail: String.LocalizationValue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PairingSetupStepTitle(number: number, title: text(title))
            Text(text(detail)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: "Onboarding")
    }
}


struct PairingSetupStepTitle: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(number, format: .number).font(.caption.weight(.semibold)).monospacedDigit()
                .frame(width: 22, height: 22)
                .background(Color(.tertiarySystemFill), in: Circle())
                .accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("pairingSetupStep\(number)")
        }
    }
}
