import SwiftUI

/// Navigation targets: a folder level or a concrete entry.
enum BrowseTarget: Hashable {
    case folder(String) // full prefix path, no trailing slash
    case entry(String)  // full entry name
}

struct StoreListView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingAdd = false
    @State private var showingSync = false
    @State private var showingAuthenticatorImport = false
    @State private var showingBackup = false

    var body: some View {
        List {
            // 2.0: PassPony generates an age identity on first run, and git
            // sync never carries it, so say so until it is backed up.
            if !KeyBackupState.backedUp, model.format == .passage, AgeIdentityStore.hasIdentities {
                Section {
                    Button {
                        showingBackup = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Your key isn't backed up")
                                    .foregroundStyle(.primary)
                                Text("If you lose this phone, your passage entries can't be read without it. Tap to back it up.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            if let status = model.syncStatus, status.ahead > 0 {
                Section {
                    Label(
                        "\(Int(status.ahead)) unpushed changes",
                        systemImage: "arrow.up.circle"
                    )
                    .foregroundStyle(.orange)
                }
            }
            if model.searchText.isEmpty {
                FolderLevelSections(prefix: "")
            } else {
                searchResults
            }
        }
        // Re-key on language change so the visible rows re-resolve without
        // remounting the sheets attached further down this chain.
        .id(model.language)
        .navigationTitle("PassPony")
        .navigationDestination(for: BrowseTarget.self) { target in
            switch target {
            case .folder(let path):
                FolderView(path: path)
            case .entry(let name):
                EntryDetailView(name: name)
            }
        }
        .searchable(text: $model.searchText, prompt: "Search all entries")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSync = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("syncButton")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityIdentifier("settingsButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("addButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingAuthenticatorImport = true
                    } label: {
                        Label("Import from Authenticator", systemImage: "qrcode")
                    }
                    Button {
                        showingBackup = true
                    } label: {
                        Label("Back up keys", systemImage: "externaldrive")
                    }
                    .accessibilityIdentifier("backupKeysButton")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("moreMenu")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddEntryView()
        }
        .sheet(isPresented: $showingSync) {
            SyncView()
        }
        .sheet(isPresented: $showingAuthenticatorImport) {
            AuthenticatorImportView()
        }
        .sheet(isPresented: $showingBackup) {
            NavigationStack {
                BackupView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingBackup = false }
                                .accessibilityIdentifier("backupDoneButton")
                        }
                    }
            }
        }
        .sheet(isPresented: $model.showingSettings) {
            SettingsView()
        }
        .overlay {
            if model.visibleEntries.isEmpty {
                ContentUnavailableView(
                    "No entries",
                    systemImage: "key",
                    description: Text("Add an entry, or clone your store in Sync.")
                )
            }
        }
    }

    /// Global flat results while searching.
    private var searchResults: some View {
        Section("Results") {
            ForEach(model.visibleEntries, id: \.name) { entry in
                NavigationLink(value: BrowseTarget.entry(entry.name)) {
                    EntryRow(name: entry.name, showFolder: true)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    model.deleteEntry(model.visibleEntries[index].name)
                }
            }
        }
    }
}

/// One drilled-in folder level.
struct FolderView: View {
    @EnvironmentObject var model: AppModel
    let path: String

    var body: some View {
        List {
            FolderLevelSections(prefix: path + "/")
        }
        .navigationTitle(path.components(separatedBy: "/").last ?? path)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Subfolders and direct entries at one level of the tree, from the flat
/// index — folders first, then entries, both sorted, mirroring `pass ls`.
struct FolderLevelSections: View {
    @EnvironmentObject var model: AppModel
    let prefix: String

    var body: some View {
        let level = computeLevel()
        if !level.folders.isEmpty {
            Section {
                ForEach(level.folders, id: \.self) { folder in
                    NavigationLink(value: BrowseTarget.folder(prefix + folder)) {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            Text(folder)
                            Spacer()
                            Text("\(count(inFolder: folder))")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        }
                    }
                }
            }
        }
        if !level.entries.isEmpty {
            Section {
                ForEach(level.entries, id: \.self) { leaf in
                    NavigationLink(value: BrowseTarget.entry(prefix + leaf)) {
                        EntryRow(name: prefix + leaf, showFolder: false)
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        model.deleteEntry(prefix + level.entries[index])
                    }
                }
            }
        }
    }

    private func computeLevel() -> (folders: [String], entries: [String]) {
        var folders = Set<String>()
        var entries: [String] = []
        for entry in model.visibleEntries where entry.name.hasPrefix(prefix) {
            let rest = entry.name.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                folders.insert(String(rest[..<slash]))
            } else {
                entries.append(String(rest))
            }
        }
        return (folders.sorted(), entries.sorted())
    }

    private func count(inFolder folder: String) -> Int {
        let folderPrefix = prefix + folder + "/"
        return model.visibleEntries.filter { $0.name.hasPrefix(folderPrefix) }.count
    }
}

struct EntryRow: View {
    let name: String
    var showFolder = true

    var body: some View {
        HStack {
            Image(systemName: "key.fill")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading) {
                Text(name.components(separatedBy: "/").last ?? name)
                if showFolder {
                    let folder = name.components(separatedBy: "/").dropLast().joined(separator: "/")
                    if !folder.isEmpty {
                        Text(folder)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
