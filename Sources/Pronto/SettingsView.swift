import SwiftUI
import Angstrom

/// Connection settings: La Marzocco account credentials + machine selection.
struct SettingsView: View {
    @Environment(MachineController.self) private var controller

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 12) {
            Form {
                if controller.hasCredentials {
                    signedInSection
                } else {
                    credentialsSection
                }

                Section("Status") {
                    LabeledContent("Connection") {
                        connectionLabel
                    }
                    if !controller.machines.isEmpty {
                        Picker("Machine", selection: Binding(
                            get: { controller.selectedSerial ?? "" },
                            set: { controller.selectMachine($0) }
                        )) {
                            ForEach(controller.machines) { machine in
                                Text("\(machine.displayName) — \(machine.modelName)").tag(machine.serialNumber)
                            }
                        }
                    }
                }

                privacySection
            }
            .formStyle(.columns)

            versionFooter
        }
        .padding(20)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Opt-in, anonymous crash reporting. Defaults off. The caption states the
    /// privacy guarantee that `SensitiveDataScrubber` enforces.
    @ViewBuilder
    private var privacySection: some View {
        Section("Privacy") {
            Toggle("Send anonymous crash reports", isOn: Binding(
                get: { controller.crashReportingEnabled },
                set: { controller.crashReportingEnabled = $0 }
            ))
            Text("Helps fix crashes. Never includes your La Marzocco account or machine details — only the crash itself. Off by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// App version footer so users can see (and copy, for bug reports) exactly
    /// which build they're on. Reads `CFBundleShortVersionString`, which
    /// `make-app.sh` derives from the git tag (e.g. "0.4.0").
    @ViewBuilder
    private var versionFooter: some View {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        Text("Pronto \(version)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Shown once credentials are stored: the account is read-only here. To change
    /// the password, sign out and sign back in.
    @ViewBuilder
    private var signedInSection: some View {
        Section("La Marzocco Account") {
            LabeledContent("Signed in as") {
                Text(controller.username).textSelection(.enabled)
            }

            Button(role: .destructive) {
                controller.signOut()
                email = ""
                password = ""
            } label: {
                Text("Sign Out & Clear Credentials")
            }
        }
    }

    /// Shown when no credentials are stored (fresh install or after sign-out).
    @ViewBuilder
    private var credentialsSection: some View {
        Section("La Marzocco Account") {
            TextField("Email", text: $email)
                .textContentType(.username)
            SecureField("Password", text: $password)
                .textContentType(.password)
            Text("The same email and password you use in the official La Marzocco app. Stored in your macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                controller.saveCredentials(username: email.trimmingCharacters(in: .whitespaces),
                                           password: password)
            } label: {
                Text("Save & Connect")
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || password.isEmpty)
        }
    }

    @ViewBuilder
    private var connectionLabel: some View {
        switch controller.connection {
        case .notConfigured:
            Text("Not configured").foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
            }
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }
}
