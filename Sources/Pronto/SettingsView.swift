import SwiftUI
import Angstrom

/// Connection settings: La Marzocco account credentials + machine selection.
struct SettingsView: View {
    @EnvironmentObject private var controller: MachineController

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        Form {
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

            if controller.hasCredentials {
                Section {
                    Button(role: .destructive) {
                        controller.signOut()
                        email = ""
                        password = ""
                    } label: {
                        Text("Sign Out & Clear Credentials")
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if email.isEmpty { email = controller.username }
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
