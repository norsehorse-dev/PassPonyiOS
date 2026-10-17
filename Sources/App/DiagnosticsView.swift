import AuthenticationServices
import SwiftUI
import UIKit

/// Settings, then Diagnostics: the screen the support page describes,
/// with the rows the inline section used to show plus app, iOS, device,
/// autofill, language, and key state, and two ways to get it into a
/// support message. Everything shown is assembled by `DiagnosticsReport`;
/// this view only collects the inputs. Nothing here decrypts, loads a key,
/// or touches the network.
///
/// Copy uses the plain pasteboard rather than the 45-second ephemeral one:
/// the report holds no secret, and it is meant to be pasted somewhere a
/// minute later.
struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @State private var autofillEnabled = false
    @State private var copied = false

    private var report: DiagnosticsReport {
        let format = model.format
        let keys: DiagnosticsReport.KeyInfo
        switch format {
        case .passage:
            keys = .passage(
                identitiesPresent: FileManager.default.fileExists(atPath: AgeIdentityStore.identitiesFile.path)
            )
        case .pass:
            let files = (try? FileManager.default.contentsOfDirectory(
                at: PGPKeyStore.keyDirectory, includingPropertiesForKeys: nil
            )) ?? []
            keys = .pass(keyFiles: files.count)
        }
        let git = model.syncStatus.map { status in
            let url = status.hasRemote ? model.git?.remoteUrl() : nil
            return DiagnosticsReport.GitInfo(
                ahead: Int(status.ahead),
                behind: Int(status.behind),
                dirty: status.dirty,
                remoteHost: status.hasRemote ? DiagnosticsReport.remoteHost(url) : nil,
                scheme: url.map { Self.schemeName(remoteScheme(url: $0)) },
                hostPinned: url.flatMap { sshKnownHostsName(url: $0) }.map { SshKeyStore.isPinned($0) }
            )
        }
        let info = Bundle.main.infoDictionary
        return DiagnosticsReport(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            coreVersion: coreVersion(),
            systemVersion: UIDevice.current.systemVersion,
            device: Self.deviceIdentifier,
            format: format == .passage ? "passage" : "pass",
            storePath: StorePaths.storeRoot(for: format).path,
            entryCount: model.entries.count,
            git: git,
            autofillEnabled: autofillEnabled,
            languageTag: AppLanguage.current,
            keys: keys,
            sshKey: SshKeyStore.load()?.algorithm
        )
    }

    var body: some View {
        let report = self.report
        Form {
            Section {
                LabeledContent("App", value: "\(report.appVersion) (\(report.build))")
                LabeledContent("Core", value: report.coreVersion)
                LabeledContent("iOS", value: report.systemVersion)
                LabeledContent("Device", value: report.device)
                LabeledContent("Format", value: report.format == "passage" ? L("passage (age)") : L("pass (OpenPGP)"))
                LabeledContent("Store path", value: report.storePath)
                LabeledContent("Entries", value: "\(report.entryCount)")
                if let git = report.git {
                    LabeledContent("Git", value: Self.gitLine(git))
                } else {
                    LabeledContent("Git", value: L("not configured"))
                }
                LabeledContent("Autofill", value: report.autofillEnabled ? L("on") : L("off"))
                LabeledContent("Language", value: report.languageTag.isEmpty ? L("system") : report.languageTag)
                switch report.keys {
                case .pass(let count):
                    LabeledContent("Keys", value: L("\(count) OpenPGP key files"))
                case .passage(let present):
                    LabeledContent("Keys", value: present ? L("identities file present") : L("no identities file"))
                }
                LabeledContent("SSH key", value: report.sshKey ?? L("none"))
            } footer: {
                Text("This report has no entry names, secrets, key fingerprints, or remote credentials. Paste it into a support message or a GitHub issue.")
            }

            Section {
                Button {
                    UIPasteboard.general.string = report.render()
                    copied = true
                } label: {
                    Label("Copy report", systemImage: "doc.on.doc")
                }
                ShareLink(item: report.render()) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                if copied {
                    Text("Report copied.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let state = await ASCredentialIdentityStore.shared.state()
            autofillEnabled = state.isEnabled
        }
    }

    /// The same arrows the old Settings row used, plus the remote's host.
    private static func gitLine(_ git: DiagnosticsReport.GitInfo) -> String {
        var line = "↑\(git.ahead) ↓\(git.behind)"
        if git.dirty { line += " (dirty)" }
        if let scheme = git.scheme { line += " \(scheme)" }
        if let host = git.remoteHost { line += " \(host)" }
        if let pinned = git.hostPinned { line += pinned ? " (host pinned)" : " (host not pinned)" }
        return line
    }

    private static func schemeName(_ scheme: RemoteScheme) -> String {
        switch scheme {
        case .https: return "https"
        case .http: return "http"
        case .ssh: return "ssh"
        case .file: return "file"
        case .other: return "other"
        }
    }

    /// The hardware identifier ("iPhone17,1"), which says more in a bug
    /// report than the marketing name and carries nothing personal.
    private static var deviceIdentifier: String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return machine.isEmpty ? UIDevice.current.model : machine
    }
}
