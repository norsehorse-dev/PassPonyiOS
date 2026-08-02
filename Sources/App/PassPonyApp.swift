import SwiftUI

@main
struct PassPonyApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked = true

    var body: some View {
        NavigationStack {
            StoreListView()
        }
        .redacted(reason: locked ? .privacy : [])
        .overlay {
            if locked {
                LockedView {
                    Task { await unlock() }
                }
            }
        }
        .task {
            model.openStore()
            await unlock()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                if !UnlockGate.isFresh { locked = true }
            case .active:
                if locked, !UnlockGate.isFresh {
                    Task { await unlock() }
                } else if UnlockGate.isFresh {
                    locked = false
                }
            default:
                break
            }
        }
    }

    private func unlock() async {
        if UnlockGate.isFresh {
            locked = false
            return
        }
        locked = !(await UnlockGate.authenticate())
    }
}

struct LockedView: View {
    var onUnlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("PassPony is locked")
                    .font(.headline)
                Button("Unlock", action: onUnlock)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
