# Repository guidance

Applies to the entire repository.

## Project and layout

SlurmBar is a native SwiftUI macOS menu bar app for viewing Slurm allocation over an existing external SSH connection. It requires macOS 14+ and Swift 6, uses Swift Package Manager, and has no third-party dependencies.

- `Sources/SlurmBarCore/`: static SSH configuration discovery, socket transport, Slurm queries, parsing, and snapshot models.
- `Sources/SlurmBar/`: SwiftUI/AppKit UI, hover help, and the `@MainActor` application model that manages settings and polling.
- `Tests/SlurmBarCoreTests/`: XCTest coverage for discovery, transport, and parsing.
- `Tests/SlurmBarTests/`: Swift Testing coverage for application state and hover help.
- `Resources/`: bundle metadata and app icons; `scripts/`: app, DMG, and icon generation; `.github/workflows/`: tests and tagged releases.

## Working conventions

- Inspect the current working tree before editing and preserve unrelated changes.
- Follow nearby Swift style and keep changes focused. Keep parsing and SSH logic in the core target and UI/state coordination in the app target.
- Preserve Swift 6 concurrency checking, actor isolation, cancellation, and subprocess time/output limits. Actor isolation alone does not prevent overlapping work across `await` points.
- Update the README when changing setup, visible behavior, polling, or packaging.
- Keep generated `.build/`, `.swiftpm/`, and `dist/` output out of version control.

## Behavior to preserve

- Reuse a user-created OpenSSH ControlMaster socket. Never initiate authentication, create a master, or fall back to a new network connection when the socket disappears.
- Keep host discovery static: do not execute SSH configuration commands, resolve DNS, or modify the user's SSH configuration. Ambiguous settings require a manual socket path.
- Retain socket ownership/path validation and transport options that disable configuration loading, forwarding, local commands, and connection fallback.
- Query only the selected host, starting with no host selected on every launch. Monitoring requires an active external channel; a persistent master alone is insufficient. Unsupported channel inspection pauses monitoring.
- Serialize refreshes. Preserve the 30-second minimum between query attempts and failure backoff, including manual refresh, reconnects, and reconfiguration.
- Keep remote queries fixed and read-only, without interpolating user input. Each refresh uses one `sinfo` and one `squeue` query; avoid per-partition polling.
- Display scheduler allocation rather than measured utilization. Deduplicate nodes across partitions for the menu bar total. Preserve the distinction between unavailable pending counts and zero, and filter personal jobs by the remote numeric user ID.

## Validation and packaging

- Run `swift test` for code changes; CI runs the same command on macOS. Add regression coverage for meaningful changes to parsing, transport, scheduling, or state behavior using the existing test framework in that target.
- Keep tests independent of a real cluster. Use fixtures, temporary sockets, isolated UserDefaults suites, and `AppModel(defaults:startMonitoring: false)` where appropriate.
- For UI changes, build with `./scripts/build-app.sh` and inspect `dist/SlurmBar.app` when a GUI session is available. Automated tests do not establish correct rendering or live SSH monitoring; report what was actually checked.
- For packaging changes, use `./scripts/build-dmg.sh`. Universal release packaging uses `./scripts/build-dmg.sh --arch arm64 --arch x86_64` and requires the corresponding macOS toolchain support.
- Release verification uses `lipo` for both architectures, `codesign --verify --deep --strict dist/SlurmBar.app`, and `hdiutil verify dist/SlurmBar.dmg`. Builds are ad-hoc signed, without notarization.
- Publishing a `vMAJOR.MINOR.PATCH` tag triggers a GitHub Release. Do not push release tags or publish releases unless requested.
