import Foundation

/// What the Diagnostics screen shows and what Copy report puts on the
/// clipboard: the facts a support thread needs and nothing a support
/// thread should ever see. No entry names, no key fingerprints, no path
/// outside the app container, and of a git remote only its host, never
/// the userinfo the core warns may carry a token.
///
/// The rendered text is English on purpose. It is written for the
/// developer reading a bug report; the screen shows the same values under
/// localized labels. Same rows and the same wording as the Android report,
/// so one support paragraph covers both.
struct DiagnosticsReport: Equatable {
    struct GitInfo: Equatable {
        var ahead: Int
        var behind: Int
        var dirty: Bool
        /// Already reduced to a host by `remoteHost`; nil when no remote.
        var remoteHost: String?
    }

    enum KeyInfo: Equatable {
        /// pass: how many OpenPGP key files are imported. Never which.
        case pass(keyFiles: Int)
        /// passage: whether the age identities file exists. Never its content.
        case passage(identitiesPresent: Bool)
    }

    var appVersion: String
    var build: String
    var coreVersion: String
    var systemVersion: String
    var device: String
    var format: String
    var storePath: String
    var entryCount: Int
    /// nil when the store has no git repository.
    var git: GitInfo?
    var autofillEnabled: Bool
    /// A BCP 47 tag, or empty for "follow the system".
    var languageTag: String
    var keys: KeyInfo

    func render() -> String {
        var lines: [String] = []
        lines.append("PassPony iOS diagnostics")
        lines.append("App: \(appVersion) (\(build))")
        lines.append("Core: \(coreVersion)")
        lines.append("iOS: \(systemVersion)")
        lines.append("Device: \(device)")
        lines.append("Format: \(format)")
        lines.append("Store path: \(storePath)")
        lines.append("Entries: \(entryCount)")
        if let git {
            var value = "ahead \(git.ahead), behind \(git.behind)"
            if git.dirty { value += ", dirty" }
            value += ", remote \(git.remoteHost ?? "none")"
            lines.append("Git: \(value)")
        } else {
            lines.append("Git: not configured")
        }
        lines.append("Autofill: \(autofillEnabled ? "on" : "off")")
        lines.append("Language: \(languageTag.isEmpty ? "system" : languageTag)")
        switch keys {
        case .pass(let count):
            lines.append("Keys: \(count) OpenPGP key files")
        case .passage(let present):
            lines.append("Keys: \(present ? "identities file present" : "no identities file")")
        }
        return lines.joined(separator: "\n")
    }

    /// The host of a git remote and nothing else. Handles the URL forms the
    /// app writes (`https://user:token@host/you/store.git`) and the scp-like
    /// form a cloned config may carry (`git@host:you/store.git`). Anything
    /// unparsable becomes nil rather than leaking through.
    static func remoteHost(_ url: String?) -> String? {
        guard let url, !url.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if url.contains("://") {
            guard let host = URLComponents(string: url)?.host, !host.isEmpty else { return nil }
            return host
        }
        let rest: Substring
        if let at = url.firstIndex(of: "@") {
            rest = url[url.index(after: at)...]
        } else {
            rest = url[...]
        }
        let host = rest.prefix { $0 != ":" && $0 != "/" }
        guard !host.isEmpty, !host.contains(" ") else { return nil }
        return String(host)
    }
}
