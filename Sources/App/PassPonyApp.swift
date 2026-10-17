import SwiftUI

@main
struct PassPonyApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Point Bundle.main at the stored language override before any view
        // resolves a string, so a launch in an overridden language starts
        // correct everywhere.
        AppLanguage.activate()
        #if DEBUG
        // App Store screenshots (fastlane snapshot, -seedDemoStore): skip
        // the tour and the key backup banner so the UI test lands straight
        // on the demo store. DEBUG builds only.
        if ProcessInfo.processInfo.arguments.contains("-seedDemoStore") {
            UserDefaults.standard.set(true, forKey: "passpony.onboardingCompleted")
            KeyBackupState.markBackedUp()
        }
        #endif
    }

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
    @AppStorage("passpony.onboardingCompleted") private var onboardingCompleted = false
    @State private var locked = true

    var body: some View {
        Group {
            if onboardingCompleted {
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
            } else {
                // First run (or a replay from Settings): the tour replaces
                // the lock screen and the store list until finished or
                // skipped. The store is already open so the interactive
                // slides act on the real thing.
                OnboardingView {
                    onboardingCompleted = true
                    // Reopen so anything gated on tour completion (the
                    // DEBUG demo seed in particular) runs now instead of
                    // waiting for the next launch.
                    model.openStore()
                    Task { await unlock() }
                }
            }
        }
        // Live language override. No .id() here: remounting the whole tree
        // would tear down and re-present the Settings sheet (a visible
        // jump). The mounted surfaces re-key themselves instead
        // (SettingsView's Form, StoreListView's List, OnboardingView's
        // pager).
        .environment(\.locale, model.language.isEmpty ? .autoupdatingCurrent : Locale(identifier: model.language))
        .task {
            model.openStore()
            model.importInbox()
            if onboardingCompleted { await unlock() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard onboardingCompleted else { return }
            switch phase {
            case .background:
                // Restart the grace window from now while unlocked; a
                // locked app stays locked.
                if !locked { UnlockGate.markLeftForeground() }
                if !UnlockGate.isFresh { locked = true }
            case .active:
                model.importInbox()
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
