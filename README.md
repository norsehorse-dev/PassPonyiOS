# PassPony (iOS)

A password manager that speaks pass and passage: plain encrypted files, your
keys, git sync. SwiftUI app over the shared Rust core (PassPonyCore).

- Browse, search, and edit entries in pass (OpenPGP) and passage (age)
  stores. Each format keeps its own store; switching never touches the
  other store's data.
- Live TOTP with a countdown ring; ephemeral, local-only clipboard that
  clears after 45 seconds.
- Git sync: clone, publish, push, and per-entry conflict resolution.
  Commit messages match the pass CLI format, so a store stays
  interoperable with desktop pass and passage users.
- QuickType autofill through a credential provider extension. Only entry
  names are indexed; nothing decrypts until you fill.
- Face ID / Touch ID unlock with a 5-minute grace window shared with
  autofill.
- Localized in English, Spanish, French, German, Simplified Chinese,
  Brazilian Portuguese, and Russian, with live in-app language switching.
- First-run tour: pick a language, choose a format, clone an existing
  store or import keys, add a first pass, and turn on autofill without
  leaving the app.

## First build

Prereqs: Xcode 16+, rustup, `brew install xcodegen`, PassPonyCore checked
out (default assumed at `~/Apps/PassPonyCore`; override with
`PASSPONY_CORE`).

```
bash scripts/build-core.sh
xcodegen generate
open PassPony.xcodeproj
```

`DEVELOPMENT_TEAM` in `project.yml` is pinned to the NorseHorse team;
change it to yours, and adjust the app group if your team prefix requires
it (also in `Sources/Shared/StorePaths.swift` and both `.entitlements`
files). The project is generated: version, team, and build settings live
in `project.yml`, and anything set in the Xcode target editor is reverted
on the next xcodegen run.

`scripts/build-core.sh` rebuilds the Rust core into
`Vendor/PassFFI.xcframework` and regenerates
`Sources/Generated/PassFFI.swift`. Rerun it whenever PassPonyCore changes.
Both outputs are gitignored; `project.yml` is the source of truth for the
Xcode project.

## Layout

- `Sources/App`: SwiftUI app (list/search, entry detail, editing, sync UI
  with the per-file conflict sheet, settings, onboarding).
- `Sources/Autofill`: ASCredentialProviderExtension serving QuickType
  fills from the app-group store.
- `Sources/Shared`: engine seam, store paths, unlock gate, language
  override, and the string catalog. Compiled into both targets.
- `Sources/Generated`, `Vendor/`: build products of
  `scripts/build-core.sh`.

## Crypto

passage stores run on AgePonyCore (pure-Swift age v1). pass stores run on
NorseHorsePGPCore (Cv25519 v4 and X25519/Ed25519 v6 keys in software).
RSA-keyed stores need the smartcard path, which is not implemented yet;
software RSA decrypt is deliberately absent from the core. DEBUG builds
fall back to a byte-flip stand-in engine only when a real engine cannot
load; release builds trap instead.

## Not yet

- Smartcard decrypt (NFC and USB-C YubiKey). Scaffolding exists behind
  the spike memo in PassPonyCore docs.
- SSH remotes for git sync; use HTTPS with a token for now.
- Passphrase-protected identities files for passage.

## License

Apache-2.0. See LICENSE.
