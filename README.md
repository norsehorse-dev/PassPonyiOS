# PassPony (iOS)

SwiftUI app over the shared Rust core (PassPonyCore). Browse, search, view,
add, and delete entries in pass/passage stores; live TOTP; git sync with
per-file conflict resolution; QuickType autofill extension.

Crypto note: DEBUG builds use `DevFlipEngine` — a byte-flip stand-in, not
crypto — so the full app runs in the simulator today. The real engines
(NorseHorsePGPCore, AgePony Swift) plug into `EngineProvider`, the single
seam, and release builds trap until they do.

## First build

Prereqs: Xcode 15+, rustup, `brew install xcodegen`, PassPonyCore checked out
(default assumed at `~/Apps/PassPonyCore`; override with `PASSPONY_CORE`).

```
bash scripts/build-core.sh
xcodegen generate
open PassPony.xcodeproj
```

Then set your development team in Signing & Capabilities (both targets), and
adjust the app group if your team prefix requires it (also in
`Sources/Shared/StorePaths.swift` and both `.entitlements` files).

`scripts/build-core.sh` rebuilds the Rust core into
`Vendor/PassFFI.xcframework` and regenerates `Sources/Generated/PassFFI.swift`
— rerun it whenever PassPonyCore changes. Both outputs are gitignored;
`project.yml` is the source of truth for the Xcode project.

## Layout

- `Sources/App` — SwiftUI app: list/search, entry detail (reveal, ephemeral
  clipboard, TOTP ring), add entry, sync UI with the conflict sheet from
  PassPonyCore `docs/conflict-ux.md`.
- `Sources/Autofill` — ASCredentialProviderExtension: picker UI backed by the
  shared app-group store, plus `SpikeChecksView` — the week-one spike checks
  (NFC availability, CryptoTokenKit slots, token keychain visibility) from
  the CoreNFC spike memo. Run those on an iPhone 15+ with a USB-C YubiKey
  inserted and record the verdicts back into the memo.
- `Sources/Shared` — engine seam, store paths (app group), used by both
  targets.
- `Sources/Generated`, `Vendor/` — build products of `scripts/build-core.sh`.

## Known P3 to-dos

- Wire real crypto engines behind `EngineProvider` (passphrase caching via
  app group + keychain, the PGPony 5-minute pattern).
- Smartcard decrypt in the main app (NFC + USB-C), bounce-back flow per the
  spike memo.
- Edit view for existing entries (field-level, byte-faithful via
  `entrySetField` / `entrySetPassword`).
- `ASCredentialIdentityStore` population from the entry index for QuickType.
- Store settings: format choice, iCloud-backup exclusion toggle, remote
  setup with SSH once the credentials callback lands in core.
