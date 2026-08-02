import SwiftUI

struct StoreListView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingAdd = false
    @State private var showingSync = false
    @State private var showingSettings = false

    var body: some View {
        List {
            if let status = model.syncStatus, status.ahead > 0 {
                Section {
                    Label(
                        "\(status.ahead) unpushed change\(status.ahead == 1 ? "" : "s")",
                        systemImage: "arrow.up.circle"
                    )
                    .foregroundStyle(.orange)
                }
            }
            Section {
                ForEach(model.visibleEntries, id: \.name) { entry in
                    NavigationLink(value: entry.name) {
                        EntryRow(name: entry.name)
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        model.deleteEntry(model.visibleEntries[index].name)
                    }
                }
            }
        }
        .navigationTitle("PassPony")
        .navigationDestination(for: String.self) { name in
            EntryDetailView(name: name)
        }
        .searchable(text: $model.searchText, prompt: "Search entries")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSync = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddEntryView()
        }
        .sheet(isPresented: $showingSync) {
            SyncView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .overlay {
            if model.visibleEntries.isEmpty {
                ContentUnavailableView(
                    "No entries",
                    systemImage: "key",
                    description: Text("Add an entry or clone your store in Sync.")
                )
            }
        }
    }
}

struct EntryRow: View {
    let name: String

    var body: some View {
        HStack {
            Image(systemName: name.contains("/") ? "folder" : "key.fill")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading) {
                Text(entryLeaf)
                if !entryFolder.isEmpty {
                    Text(entryFolder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var entryLeaf: String {
        name.components(separatedBy: "/").last ?? name
    }

    private var entryFolder: String {
        name.components(separatedBy: "/").dropLast().joined(separator: "/")
    }
}
