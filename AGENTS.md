# WhatCable

macOS menu bar app + CLI that reports what each USB-C cable can actually do. Reads USB-PD Discover Identity, Thunderbolt link state, and IOKit port-controller data.

## Repo model

This is the primary development repo (private). All work happens here.
The public OSS repo (`darrylmorley/whatcable`) is a filtered mirror that
receives every commit except pro source files.

- **Do not push directly to the public repo.** All changes go through
  this repo and sync automatically via the mirror GitHub Action on every
  push to `main` and every `v*` tag.
- Pro source code lives at `Sources/WhatCablePlugins/`. The public repo
  gets a no-op stub at the same path. `.public-exclude` at the repo root
  is the single source of truth for what gets filtered out.
- To pull a contributor PR from the public repo:
  `gh pr checkout <n> --repo darrylmorley/whatcable`, rebase onto main,
  merge `--ff-only`, push to origin. Then close the PR on public:
  `gh pr close <n> --repo darrylmorley/whatcable --comment "Merged upstream."`
- Release script creates GH releases on the public repo
  (`--repo darrylmorley/whatcable`). It waits for the mirror action
  to push the tag before calling `gh release create`.
- Homebrew cask points to public repo releases. No separate step needed.
- Worker repo (`darrylmorley/whatcable-worker`) is separate, no dependency.

## Repo identity (gotcha)

- **Private repo (this one):** `darrylmorley/whatcable-app`. Local dir: `~/Projects/personal/whatcable-app`.
- **Public mirror:** `darrylmorley/whatcable` (no hyphen). Issues, releases, and contributor PRs live here.
- Homebrew tap: **`darrylmorley/homebrew-whatcable`**, local clone at `~/Projects/personal/homebrew-whatcable`.
- Bundle ID: `uk.whatcable.whatcable`. App name: `WhatCable`. CLI binary name: `whatcable` (lowercase).

## Stack

- Swift Package Manager. Min macOS 14 (Sonoma). Apple Silicon primary; Intel Macs are explicitly unsupported (Titan Ridge / JHL9580 don't expose the IOKit data we need). The package is macOS-only (`platforms: [.macOS(.v14)]`); a Windows port is in progress (see `planning/windows-port.md`).
- Targets:
  - `WhatCableCore`: models, formatters, diagnostic engine, vendor DB. Zero platform imports (no `import IOKit`, no `import Darwin`). Compiles on macOS and Windows. Also contains `WidgetSnapshot`, the shared Codable model the widget reads.
  - `WhatCableDarwinBackend`: IOKit watchers (`USBCPortWatcher`, `PowerSourceWatcher`, `PDIdentityWatcher`, `USBWatcher`), `DarwinSnapshotProvider`, and `DarwinSystemInfo` (sysctlbyname hw.model lookup).
  - `WhatCableWindowsBackend`: Windows-side `CableSnapshotProvider` and `WindowsSystemInfo`. Currently stubs. Will use SetupAPI/CfgMgr32 for USB-C enumeration and WMI for hardware info.
  - `WhatCableWindowsCLI` -> product `whatcable-windows-cli`. Entry point for the Windows CLI, wires `WindowsSnapshotProvider` to `TextFormatter`.
  - `WhatCableAppKit`: plugin registry and extension points. Defines `PluginRegistry`, `CLICommand`, `MenuPlacement`, `PluginMenuItem`, `PortCardContext`, `WidgetDataContributor`. No IOKit, no SwiftUI. Both the app and CLI depend on this.
  - `WhatCablePlugins`: pro feature implementations (diagnostics, power telemetry, licence manager, DisplayPort, liquid detection). Depends on `WhatCableCore`, `WhatCableDarwinBackend`, and `WhatCableAppKit`. The public mirror gets a no-op stub at this path. Pro tests live in `Tests/WhatCablePluginsTests/`.
  - `WhatCable` (SwiftUI menu bar app). `WidgetDataWriter` writes cable state to the App Group shared container and pushes WidgetKit reloads.
  - `WhatCableCLI` -> product `whatcable-cli` (binary name: `whatcable`).
  - `WhatCableWidget` (WidgetKit extension, built via Xcode). Lives in `Sources/WhatCableWidget/`. Small/medium/large desktop widgets showing cable status. Reads from App Group `UserDefaults`, no IOKit dependency.
- `swift build` and `swift test` are the entry points. CI runs the macOS test job and a script-syntax lint; that's it.
- The widget extension is built separately via `xcodebuild` (SPM can't produce `.appex` bundles). `project.yml` is the XcodeGen spec; run `xcodegen generate` to produce the gitignored `WhatCableWidget.xcodeproj`. The build scripts handle this automatically.
- Full build process, plugin architecture, and app bundle layout are documented in `BUILDING.md` (gitignored, local only since it covers Pro details).

### Linux is intentionally not on the roadmap

A Linux backend stub existed briefly and was removed in commit `fe53929`. Issue [#11](https://github.com/darrylmorley/whatcable/issues/11) stays open as a public placeholder, but the project's stance is "WhatCable is a Mac app." Don't reintroduce a Linux backend, conditional compilation, or Linux CI without explicit user direction. The local `planning/linux-port.md` is archived for historical context; ignore it as a current source.

### `CableSnapshotProvider` protocol

Two implementations: `DarwinSnapshotProvider` (macOS, IOKit) and `WindowsSnapshotProvider` (Windows, stubs for now). The protocol documents the watch-stream contract (initial snapshot, change-only updates, `onTermination` cleanup) and gives tests a seam to mock the provider.

### Thunderbolt fabric: shipped

The Thunderbolt fabric feature shipped in **v0.8.0** (PR #63). The TB5 hedge flip landed in **PR #87** off the back of the M5 Pro + UGreen JHL9580 dock paste-back from @NoFr1ends on issue #52, so all generations (TB3, TB4 / USB4, TB5) now render with confirmed per-lane labels. Issue #52 is closed; future TB-fabric edge cases should land as fresh issues. Live code: `Sources/WhatCableCore/ThunderboltLink.swift`, `Sources/WhatCableCore/ThunderboltLabels.swift`, `Sources/WhatCableDarwinBackend/ThunderboltWatcher.swift`. Full brief and confirmed-data section in `planning/thunderbolt-fabric.md`.

`whatcable --tb-debug` (shipped in v0.6.1) is the hidden contributor flag that produces TB-fabric dumps. It stays in for diagnosing future edge cases.

Key empirical points still worth keeping in mind when working in this area:

- **Port-to-switch correlation key:** parse the `@N` suffix on `USBCPort.serviceName` and match against the TB protocol port (`Adapter Type=1`) whose `Socket ID` string equals `"N"`.
- **`Current Link Speed > 0` is the "TB-protocol partner present" signal.** USB-only devices tunnel through the controller's internal USB Adapter without lighting up host-side TB link state. Don't use cable e-marker presence as the gate for "Thunderbolt link active" labels.
- **`Thunderbolt Version` is a controller-class constant**, not a per-link value. Apple `Type5` = 32, Apple `Type7` = 64, `Type3` = 16. Confirmed across M3 base, M3 Ultra, M4 mini and M5 Pro. Don't use for link-generation labels.
- **Switch class follows silicon generation, not chip family name.** M3 base MBA = `Type5` (TB4-class), M3 Ultra = `Type7` (TB5-capable), Intel `JHL8440` = TB4 dock controller, Intel `JHL9580` = TB5 dock controller. Match against the `IOThunderboltSwitch*` prefix or walk the class hierarchy via `IOObjectConformsTo`. Don't hardcode generations.
- **Watcher needs interest notifications plus polling**, mirroring the `USBCPortWatcher` pattern. Add/remove alone won't catch link-state changes.

### CIO cable capability: wired, not yet surfaced

`IOPortTransportStateCIO` exposes cable capability data from Apple's Thunderbolt controller that is independent of the USB-PD e-marker. This is the signal needed for issue #111 (active TB4 cables like CalDigit 2M that report "passive" in their e-marker).

Live code: `Sources/WhatCableCore/CIOCableCapability.swift` (model), `Sources/WhatCableDarwinBackend/TRMTransportWatcher.swift` (reads from IOKit), `Sources/WhatCableCore/JSONFormatter.swift` (exposes as `"cio"` in JSON output).

**Data flow:** `TRMTransportWatcher` already watches `IOPortTransportStateCIO` for TRM fields. It now also publishes a separate `cioCapabilities: [CIOCableCapability]` array. These flow through `CableSnapshot` and into `JSONFormatter` as a per-port `"cio"` object. `CIOCableCapability` is a standalone struct, not mixed into `TRMTransport`, because it represents Thunderbolt cable capability (related to the TB fabric) rather than access-control state (TRM's concern).

**Fields:** `cableGeneration`, `cableSpeed`, `generation`, `asymmetricModeSupported`, `legacyAdapter`, `linkTrainingMode`. All optional. Only populated when the CIO transport is active (TB link is live).

**Value mappings are unconfirmed.** Based on one data point (Amazon Basics TB4 1m, Mac-to-Mac connection): `CableGeneration=2`, `CableSpeed=3`, `Generation=3`. Need more cables (TB3, TB5, active long cables) to confirm interpretations before adding user-facing labels in PortSummary. The `probes/24_cio_transport_live.txt` file has the full dump.

**What didn't work (probes 20-24):** USB4 sideband retimer enumeration, IOThunderboltLib CFPlugin, direct MMIO, and HPM VDM selectors are all blocked from userspace on Apple Silicon. See `probes/20_*` through `probes/24_*` for the full investigation.

### Test kit (community diagnostic data)

Bundled in the app since v0.10.13 (PR #37). Runs 13 IOKit C probes that dump raw USB-C/Thunderbolt registry data and POSTs results to a Cloudflare Worker for analysis. The probes read the same IOKit data the app uses but dump it raw, giving us real-world samples across different hardware.

**Probe sources:** `probes/test-kit/*.c` (13 C files, tracked in git). These are one-shot forks of the original investigation probes with RunLoop waits removed. `smoke-test.sh` compiles them as universal binaries into `Contents/Resources/probes/` and signs them alongside the app.

**App UI flow:**
- Settings > Community section has a "Contribute Diagnostic Data" button
- Clicking it shows a consent sheet explaining what is collected and privacy details
- "Proceed" runs all 13 probes and shows progress inline
- Right-click menu item "Contribute Diagnostic Data..." opens the same consent flow
- `TestKitRunner.swift` (in the app target) is the `@MainActor ObservableObject` that manages state and execution
- `TestKitSettingsSection.swift` has the settings UI and `TestKitConsentView`

**CLI:** `whatcable --test-kit` runs the same probes with a `y/N` confirmation prompt. Implemented as a plugin command in `Sources/WhatCablePlugins/TestKitCommand.swift`, registered in `Bootstrap.swift`.

**Worker:** `https://whatcable-test-kit.darrylmorley-uk.workers.dev` with two endpoints: `POST /submit` (stores one probe result in KV, key = `{machine_hash}:{probe_name}`) and `POST /complete` (sends email notification via Resend). Worker source lives in the separate `whatcable-test-kit` repo at `~/Projects/personal/whatcable-test-kit/worker/`.

**Privacy:** Machine UUID is SHA-256 hashed before sending. No names, serial numbers, or personal data collected. macOS version and chip type are the only identifying metadata.

**KV namespace:** `WHATCABLE_PROBE_DATA` (id: `adf0dd94901d43758cb3e13b732a6db6`). Each run produces 13 KV entries per machine. Re-running from the same machine overwrites the same keys.

**Retrieving data:** No read endpoint on the worker. Use `wrangler kv key list --namespace-id adf0dd94901d43758cb3e13b732a6db6` to list submissions and `wrangler kv key get` to fetch individual probe results. Run from `~/Projects/personal/whatcable-test-kit/worker/`. See the whatcable-test-kit AGENTS.md for full retrieval commands.

### Research library

`research/` is a private reference library (excluded from the public mirror via `.public-exclude`). It contains:

- **Interpretation docs** (root): IOKit data sources, USB spec reference, TB fabric, cable trust signals, CIO value mappings.
- **`cables/`**: 30 user-submitted e-marker fingerprints from closed `cable-report` issues, one file per cable. Each has YAML frontmatter (vendor_id, speed, power, trust_flags) for search. `cables/README.md` has the full index sorted by VID.
- **`dumps/`**: verbatim ioreg/system_profiler output from community contributors (CIO, SmartBattery, HPM, TB fabric), organized per contributor per issue.

When a new cable-report issue lands, add a file to `research/cables/` following the existing format (issue number prefix, frontmatter, fingerprint table, notes). When contributors submit raw dumps on data-collection issues, add verbatim files to the appropriate `dumps/` subdirectory.

`data/known-cables.md` remains the quick-reference summary and build input. `research/cables/` is the detailed source of truth with full context.

#### Generated knowledge base

`research/` (plus `probes/test-kit/`) is the source of truth. A separate local
repo at `~/Projects/personal/apple-device-research` holds a generated,
subject-organised view of it, for reuse across the Apple device app family
(whatport, what-permission, what-cable-linux, future apps) and for navigation
in Obsidian or by an AI in a fresh session.

- Generator: `scripts/build-research-kb.swift`. Mapping config:
  `scripts/research-kb-taxonomy.json` (source path to subject). Edit the
  taxonomy to change how sources map to subjects; edit the generator to change
  layout.
- Rebuild: the `whatcable-rebuild-research` skill, or
  `swift scripts/build-research-kb.swift` from the repo root on a current
  `main`.
- The knowledge base is generated. Never hand-edit it; a rebuild overwrites
  everything except its `.git` and `.obsidian`. To change content, edit the
  source here and rebuild.
- The generator and taxonomy are private research tooling, excluded from the
  public mirror via `.public-exclude`.
- `research/customer-probes/` is a point-in-time snapshot of the
  `WHATCABLE_PROBE_DATA` KV store; the generator reads only the committed
  snapshot. Refreshing it from the live store is a separate manual step (see
  the Test kit section).

### Cable trust signals (planned)

Heuristic flags for implausible / suspicious / generic e-marker data are planned as a separate feature. Phase 1 (zeroed VID/PID + impossible PDO values) is the safe quick-win; later phases (power vs speed mismatch, VID category mismatch) need carve-outs and a curated `VendorDB` category enum. Full design in `planning/cable-trust-signals.md`. All wording stays hedged ("looks unusual," "common counterfeit pattern"), never "this cable is fake."

### Cable fingerprint database

`data/known-cables.md` is the working list of cables reported via the in-app "Report this cable" flow. It's seeded from closed `cable-report` issues. The data is compiled into `whatcable.db` (bundled in the app) and served on the website at `whatcable.uk/cables` with client-side search.

#### Runtime data: `whatcable.db`

`Sources/WhatCableCore/Resources/whatcable.db` is a SQLite database with two tables:

- **`vendors`**: ~14k vendor names from USB-IF + the community `usb.ids` list, with a `source` column (`usbif`, `usbids`, `manual`) for provenance tracking. `CableDB.vendorName(vid:)` returns names from any source; `CableDB.isUSBIFRegistered(_:)` returns true only for `source='usbif'`, preserving the trust-signal distinction.
- **`cables`**: curated cable fingerprints from `data/known-cables.md`, keyed by `(vid, pid, cable_vdo)`. `CableDB.curatedCable(vid:pid:cableVDO:)` powers brand lookup in `PortSummary`, `CableReport`, and `JSONFormatter`.

`CableDB.swift` loads everything into memory on first access, then closes the db handle. `VendorDB.swift` delegates to `CableDB` for all lookups.

#### Build script

`scripts/build-cable-db.swift` compiles the database from three sources:

1. `Sources/WhatCableCore/Resources/usbif-vendors.tsv` (USB-IF vendor list)
2. `https://usb-ids.gowdy.us/usb.ids` (community vendor list, fetched live)
3. `data/known-cables.md` (curated cable fingerprints)

Outputs:
- `Sources/WhatCableCore/Resources/whatcable.db` (bundled in the app)
- `docs/whatcable.db` (served on the website)
- `docs/cables.json` (small JSON for the website search page)

The db ships in DELETE journal mode (not WAL). WAL requires creating -shm/-wal sidecar files, which fails in read-only SPM resource bundle directories.

#### Website

The `docs/` folder is the source for the GitHub Pages site at `whatcable.uk`. **All website edits happen here in the private repo first.** The mirror workflow copies `docs/` to the public repo (`darrylmorley/whatcable`), which is where GitHub Pages actually serves from. Editing the public repo's `docs/` directly will get overwritten on the next mirror.

Pages:
- `docs/index.html` - home page
- `docs/instructions.html` - docs (free + Pro feature reference, troubleshooting FAQ)
- `docs/cli.html` - CLI docs
- `docs/cables.html` - cable database search (loads `cables.json`)
- `docs/pro.html` - Pro feature showcase and Stripe checkout
- `docs/success.html` - post-purchase activation instructions
- `docs/support.html` - licence-gated support form (noindex)
- `docs/privacy.html` - privacy policy

Nav pattern across all pages: Docs, CLI, Cables, GitHub (white button), Get Pro (accent button). Support is in the footer only.

The Pro checkout and support form talk to a Cloudflare Worker at `whatcable.uk/api/`. Worker source lives at `~/Projects/personal/whatcable-worker/` (private repo `darrylmorley/whatcable-worker`). Deployed via `npx wrangler deploy`.

`docs/cables.html` is generated by `render-known-cables.swift`. The other pages are hand-edited HTML.

#### Scripts and workflow

Three scripts run the cable data pipeline:

- `scripts/sync-cable-reports.swift` pulls every closed `cable-report` issue via `gh`, parses the e-marker fingerprint table out of each body, looks up canonical USB-IF vendor names, and rewrites the table block in `data/known-cables.md`. Idempotent; re-running on synced data is a no-op.
- `scripts/build-cable-db.swift` compiles `whatcable.db` and `cables.json` from the sources above.
- `scripts/render-known-cables.swift` reads the markdown and writes `docs/cables.html`. Validates table structure and exits non-zero on malformed input.

Workflow when a new cable-report issue lands and you've triaged + closed it:

```bash
swift scripts/sync-cable-reports.swift     # pull from gh, update md
# hand-edit any "(needs review)" rows: replace with one short brand/model phrase
swift scripts/build-cable-db.swift         # rebuild db + JSON
swift scripts/render-known-cables.swift    # rebuild docs/cables.html
git add data/known-cables.md docs/cables.html docs/cables.json docs/whatcable.db Sources/WhatCableCore/Resources/whatcable.db
```

Discipline points worth keeping:

- **The "Brand / model context" column is hand-edited only.** The sync script writes `(needs review)` for new rows. Reporter notes are never auto-imported verbatim because they contain Amazon affiliate links, accusations against named vendors, and personal purchase context. Distilling to a one-line phrase is a privacy-protecting human step.
- **Brand/model context is the first column on purpose** (since c5fadcd). Readers scan by brand first ("is my Anker cable here?"), then by VID. The renderer's `cellClasses` array, the sync script's `renderRow` order, and `loadExistingContexts`'s column index all need to stay in lockstep if you ever reorder columns again.
- **Vendor names come from the bundled database**, never from the "as reported" name on the issue body. Older WhatCable versions reported "Unregistered / unknown" for VIDs that were registered all along; v0.8.1+ ships the full list.

## Verification builds (no tap mutation)

For day-to-day "does this build cleanly, sign, notarise, and smoke-test?" runs, use:

```
scripts/smoke-test.sh
```

This does the full pipeline (tests, universal binary, sign, notarise, staple, alive-after-2s check on both binaries, zip) but does **not** touch the Homebrew tap. Safe to run any time on any branch. Its `VERSION=` and `BUILD_NUMBER=` constants are the source of truth for `Info.plist`.

The cask bump only happens via `scripts/build-app.sh`, which is a thin wrapper that calls `smoke-test.sh` then runs `bump-cask.sh`. Don't run `build-app.sh` directly outside a release. Background: running the old combined script for verification kept producing stale local commits in `$TAP_DIR` whose sha didn't match the published release, requiring manual `git reset --hard` recovery. Splitting the cask bump out makes the unsafe step opt-in.

## Release process

Everything is automated by `scripts/release.sh`. Don't piece it together by hand.

```
scripts/release.sh <version> [build-number]      # ship
scripts/release.sh --dry-run <version>           # preview
```

Required prereqs (release.sh checks all of these):

- On `main`, working tree clean.
- `release-notes/v<version>.md` exists. First line (stripped of leading `#`) becomes the GH release title suffix.
- Tag `v<version>` doesn't exist locally, on private origin, or on the public repo.
- `gh` CLI authenticated.
- `.env` configured with `DEVELOPER_ID`, `NOTARY_PROFILE`, `TAP_DIR` (see `.env.example`). The repo's `.env` is set up; signing + notarisation work end-to-end.

What release.sh does, in order:

1. Patches `VERSION` and `BUILD_NUMBER` constants in `scripts/smoke-test.sh` (these are the source of truth; they propagate into `Info.plist` at build time).
2. Commits "Bump version to X.Y.Z (build N)".
3. Runs `scripts/build-app.sh`: calls `smoke-test.sh` (build, sign, notarise, smoke-test), then bumps the cask in `TAP_DIR` (commit only, no push).
4. Tags `v<version>`, pushes `main` + tag to **private origin**. The mirror GitHub Action fires automatically and pushes the filtered commit + tag to the public repo.
5. Waits for the mirror to push the tag to public (polls `gh api` for up to 5 minutes).
6. `gh release create` on the **public repo** (`--repo darrylmorley/whatcable`) with `dist/WhatCable.zip` and the release notes.
7. Re-runs `bump-cask.sh` with `CASK_VERIFY_REMOTE=1 CASK_VERIFY_STRICT=1` to prove the uploaded asset's sha matches what was built.
8. Copies release notes into the tap, amends the cask commit, and `git push --force-with-lease` the tap.

Steps 5-8 are idempotent on re-run (delete the GH release first if you need to redo it).

### Resuming a release that failed mid-flight

`release.sh` doesn't auto-resume. If it bails part-way (network blip on `git push`, notarytool hiccup, whatever), inspect what got done and run only the remaining steps by hand. Typical recovery sequence after the build + notarise + local cask bump succeed but the push fails:

```bash
# 5. push main + tag
git push origin main && git push origin v<version>

# 6. create GH release
gh release create v<version> dist/WhatCable.zip \
  --repo darrylmorley/whatcable \
  --title "v<version>: <first-line-of-notes>" \
  --notes-file release-notes/v<version>.md

# 7. verify uploaded asset matches local
set -a; source .env; set +a
CASK_VERIFY_REMOTE=1 CASK_VERIFY_STRICT=1 ./scripts/bump-cask.sh <version> dist/WhatCable.zip

# 8. sync release notes into tap and push
cp release-notes/v<version>.md "${TAP_DIR}/release-notes/v<version>.md"
git -C "${TAP_DIR}" add release-notes/v<version>.md
git -C "${TAP_DIR}" commit --amend --no-edit
git -C "${TAP_DIR}" push --force-with-lease
```

`gh release create` is the one step that errors loudly on re-run; if you need to redo it, `gh release delete v<version>` first.

## Repo-specific things to remember

- **Build version source of truth:** `scripts/smoke-test.sh` (`VERSION=` and `BUILD_NUMBER=`). `Info.plist` is generated from these at build time. `AppInfo.swift` reads the bundle plist at runtime, falling back to "dev" under `swift run`. The widget's `project.yml` has placeholder values that get overridden by the build scripts via `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` xcodebuild args.
- **Widget extension** lives at `Contents/PlugIns/WhatCableWidget.appex` inside the app bundle. Built by `xcodebuild`, embedded and signed by the build scripts. Requires `xcodegen` (`brew install xcodegen`) to generate the Xcode project from `project.yml`. Data flows from the main app to the widget via App Group `UserDefaults` (`group.uk.whatcable.whatcable`).
- **CLI lives in `Helpers/`, not `MacOS/`.** v0.5.0 shipped broken because a case-insensitive FS collision (`whatcable` vs `WhatCable`) overwrote the menu bar binary. `smoke-test.sh` smoke-tests both binaries to catch that class of bug.
- **Tap repo's `Casks/whatcable.rb`** has version + sha256 fields. `bump-cask.sh` rewrites them. The `homebrew-whatcable` repo also keeps a mirror of `release-notes/v<version>.md` per release.
- **PRs over direct pushes for non-trivial work.** Issue fixes get a branch (`fix/issue-<n>`), PR with `Closes #<n>`, then squash-merge. The history on `main` is linear.
- **Public-visible actions need explicit go-ahead each time:** every release, GH issue change, push to main, force-push to the tap. One "yes" doesn't blanket-approve subsequent ones; one "yes" per release is enough though, no sub-confirmations needed once tests pass.

## Common ops

- `swift build` / `swift test` -- local sanity. 268+ tests; should always be green on `main`.
- `scripts/smoke-test.sh` -- full build + sign + notarise + smoke-test, no tap mutation. The right script for day-to-day verification.
- Pro features are always compiled in (the private repo includes `WhatCablePlugins` directly). Runtime gating is via `LicenceManager`, not compile-time flags.
- `whatcable --tb-debug` is a hidden contributor flag that dumps the `IOThunderboltSwitch` tree. Don't surface it in user-facing docs or the README. It's referenced from the planning doc and the (now closed) issue #52 thread; useful when a fresh TB-fabric edge case turns up.
- `scripts/release.sh --dry-run <ver>` -- validate state before committing to a release.
- `swift scripts/sync-cable-reports.swift`, then `swift scripts/build-cable-db.swift`, then `swift scripts/render-known-cables.swift`: refresh the cable fingerprint database after triaging a new `cable-report` issue. Hand-edit `(needs review)` placeholder rows between the sync and build steps.
- `DRY_RUN=1 scripts/mirror-to-public.sh` -- preview what the mirror would push without actually pushing. Useful before a release to check nothing pro is leaking.
- `scripts/mirror-to-public.sh` -- manually mirror to public. Normally the GitHub Action handles this on every push to main/tags, but the local script is there for one-off runs.
- **Grant a free Pro licence key:** `cd ~/Projects/personal/whatcable-worker && scripts/grant-licence.sh <email> "<note>"`. The note goes into the KV record's `stripeSessionId` field as `grant:<note>` so you can tell paid keys from gifted ones. Example: `scripts/grant-licence.sh contributor@example.com "Cable reporter - issue #130"`.
- `gh pr list --repo darrylmorley/whatcable` -- open work.
- `gh issue view <n> --repo darrylmorley/whatcable --comments` -- read an issue with thread.
- Tap recovery: cask commits have happened to land locally without being pushed. If `brew upgrade` is missing a version, check `git -C $TAP_DIR log` against the published GH release sha and `git push` the missing commit.
- **Never `git reset --hard` the tap to `origin/main` without first verifying the local cask sha matches the published release asset.** A previous session destroyed the only copy of the 0.5.13 cask commit doing exactly this; recovery was via reflog. Always: download the published asset, `shasum -a 256` it, compare to `Casks/whatcable.rb`, then decide whether the local commit is a stale rebuild (drop) or the real published one (push, don't reset).
- Smoke testing the GUI binary: do **not** run `.build/debug/WhatCable` directly. SwiftUI menu-bar apps need a real `.app` bundle (`UNUserNotificationCenter` aborts otherwise). The proper smoke target is `dist/WhatCable.app/Contents/MacOS/WhatCable` after `scripts/smoke-test.sh`. `smoke-test.sh` already runs an alive-after-2s check on that path.

## Working with the user

The user is a novice Swift developer and is using this project partly to learn. Lean into that:

- When introducing a Swift concept (protocols, async/await, property wrappers, actors, generics, IOKit C bridging, etc.), give a one or two sentence plain-English explanation alongside the code, not just the code.
- When suggesting an approach, briefly explain *why* it's idiomatic Swift (or why an alternative would be wrong).
- Don't assume familiarity with patterns that are obvious to a Swift-fluent reader. SwiftUI's `@State` / `@StateObject` / `@ObservedObject` distinction, Sendable conformance, structured concurrency cancellation, IOKit memory management, and Combine vs AsyncStream are common stumbling points worth a brief note when they come up.
- Code review comments and explanations stay in plain language (per the global style rules) and avoid Swift-specific jargon when a plain word works.

The user is a strong web/TS/PHP developer, so analogies to those ecosystems are useful when bridging concepts.

## Style

- No em-dashes anywhere (chat, code, commit messages, release notes, PR descriptions).
- Plain language. Short sentences. The release notes and issue comments lean conversational and credit reporters by handle.
- Don't commit planning / design / analysis docs unless asked.
