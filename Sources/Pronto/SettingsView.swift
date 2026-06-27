import SwiftUI
import Angstrom

/// Connection settings: La Marzocco account credentials + machine selection.
struct SettingsView: View {
    @Environment(MachineController.self) private var controller

    @State private var email = ""
    @State private var password = ""

    var body: some View {
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
        }
        .formStyle(.columns)
        .padding(20)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
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
