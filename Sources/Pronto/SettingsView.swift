import SwiftUI
import Angstrom

/// Which Settings tab is active — drives both the `TabView` selection and the
/// window title, so the title bar tracks the active tab like the design.
private enum SettingsTab: String {
    case account = "Account"
    case machine = "Machine"
    case privacy = "Privacy"
}

/// Settings window: Account (credentials + connection), Machine (live boiler
/// controls), and Privacy (crash reporting) tabs, with the version footer
/// visible on every tab. Grouped-inset-card look throughout, per the design
/// handoff — each tab hand-lays its own ``SettingsGroup`` cards (rather than
/// `.formStyle(.grouped)`, which is List-backed and has no intrinsic height)
/// so the toolbar-style `TabView` can auto-resize the window per tab.
struct SettingsView: View {
    @State private var selection: SettingsTab = .account

    var body: some View {
        VStack(spacing: 8) {
            TabView(selection: $selection) {
                AccountSettingsTab()
                    .tabItem { Label("Account", systemImage: "person.circle") }
                    .tag(SettingsTab.account)
                MachineSettingsView()
                    .tabItem { Label("Machine", systemImage: "dial.medium") }
                    .tag(SettingsTab.machine)
                PrivacySettingsTab()
                    .tabItem { Label("Privacy", systemImage: "hand.raised") }
                    .tag(SettingsTab.privacy)
            }
            versionFooter
                .padding(.bottom, 12)
        }
        // Every tab's content now has intrinsic height (plain VStacks, no
        // List-backed Form), so the window can size itself per tab: fixed
        // 480pt width (narrowed from the design's 600pt per user feedback),
        // free height via `fixedSize`.
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(selection.rawValue)
    }

    /// App version footer so users can see (and copy, for bug reports) exactly
    /// which build they're on. Reads `CFBundleShortVersionString`, which
    /// `make-app.sh` derives from the git tag (e.g. "0.4.0").
    @ViewBuilder
    private var versionFooter: some View {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        Text("Pronto \(version)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Account tab: La Marzocco credentials + connection status + machine picker.
private struct AccountSettingsTab: View {
    @Environment(MachineController.self) private var controller

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if controller.hasCredentials {
                signedInGroup
            } else {
                credentialsGroup
            }
            connectionGroup
        }
        .settingsTabPadding()
    }

    /// Shown once credentials are stored: the account is read-only here. To change
    /// the password, sign out and sign back in.
    private var signedInGroup: some View {
        SettingsGroup("Account") {
            SettingsRow {
                LabeledContent("Signed in as") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("La Marzocco Account")
                        Text(controller.username)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            }
            SettingsRow {
                HStack {
                    Spacer()
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
    }

    /// Shown when no credentials are stored (fresh install or after sign-out).
    private var credentialsGroup: some View {
        SettingsGroup("Account") {
            SettingsRow {
                TextField("Email", text: $email)
                    .textContentType(.username)
            }
            SettingsRow(help: "The same email and password you use in the official La Marzocco app. Stored in your macOS Keychain.") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            SettingsRow {
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
    }

    private var connectionGroup: some View {
        SettingsGroup("Connection") {
            SettingsRow {
                LabeledContent("Status") {
                    connectionLabel
                }
            }
            if !controller.machines.isEmpty {
                SettingsRow {
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

/// Privacy tab: opt-in, anonymous crash reporting. Defaults off. The caption
/// states the privacy guarantee that `SensitiveDataScrubber` enforces.
private struct PrivacySettingsTab: View {
    @Environment(MachineController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup("Privacy") {
                SettingsRow(help: "Helps fix crashes. Never includes your La Marzocco account or machine details — only the crash itself. Off by default.") {
                    Toggle("Send anonymous crash reports", isOn: Binding(
                        get: { controller.crashReportingEnabled },
                        set: { controller.crashReportingEnabled = $0 }
                    ))
                    .toggleStyle(FullWidthToggleStyle())
                    .tint(.green)
                }
            }
        }
        .settingsTabPadding()
    }
}
