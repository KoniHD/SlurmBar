# SlurmBar

[![Swift tests](https://github.com/KoniHD/SlurmBar/actions/workflows/swift.yml/badge.svg?branch=main&event=push)](https://github.com/KoniHD/SlurmBar/actions/workflows/swift.yml)

A native SwiftUI macOS menu bar app that shows Slurm node allocation using SSH connections already established by other apps, such as Terminal or VS Code Remote SSH.

## Build and run

Requires macOS 14+ and a Swift 6 toolchain (Xcode or Command Line Tools). No third-party packages.

```sh
swift test
./scripts/build-app.sh
open dist/SlurmBar.app
```

Start at login by adding the built app under System Settings → General → Login Items.

## SSH setup

Your SSH host needs ControlMaster enabled, for example:

```sshconfig
Host example-cluster
    ControlMaster auto
    ControlPersist 12h
    ControlPath ~/.ssh/master-%C
```

Connect through your usual app, then select the SSH alias from the widget’s host dropdown. Only aliases with ControlMaster enabled appear. The selection starts empty on every launch, and only the selected host is queried. SSH configuration discovery runs in the background to keep the interface responsive. SlurmBar discovers its control socket automatically; use **Configure host** in Settings to detect or manually override the socket path if needed. Terminal, VS Code, and SlurmBar must use the same control socket.

If the selected host’s saved socket is missing, SlurmBar re-reads its SSH configuration on the next monitoring check (every five seconds) and switches to the newly resolved socket if it exists and passes validation. An existing valid socket override is kept.

Monitoring requires an active external SSH channel; a persistent master alone does not activate it. Both the SSH client and master must support `-O channels`; otherwise monitoring pauses.

Selecting a host while disconnected keeps SlurmBar running and shows the connection status. Closing the host picker, dashboard, or Settings window leaves the app in the menu bar; use **Quit** to exit.

After disconnection, the last snapshot remains visible with its age. If it is more than one hour old and no usable external session is detected, SlurmBar clears the host selection and returns to the initial screen. Cached snapshots, statuses, and partition names are discarded; saved socket overrides, partition filters, refresh settings, and query backoff are retained. Select a host again to resume monitoring.

## What the display means

- **Green / idle:** available, idle CPUs.
- **Orange / mixed:** partially allocated.
- **Red / allocated:** fully allocated.
- **Gray / unavailable:** down, drained, reserved, maintenance, or otherwise unavailable.

These colors describe scheduler allocation, not measured CPU/GPU utilization. Each partition has a proportional bar showing the percentage of nodes in each state. Hover over it for counts and percentages. Each partition also shows its visible pending queue entries; array tasks remain grouped as in `squeue`, and jobs requesting multiple partitions count in each. When you have jobs in the `RUNNING` state in a partition, a green “N running” count appears to the left of pending. It counts only your remote account’s jobs and disappears when none are running, using the same queue response without extra queries. Counts reflect your account’s job visibility, so cluster privacy settings may hide other users’ jobs. Failed queue queries show “Pending unavailable” rather than zero. Nodes can belong to multiple partitions; the menu bar total counts each node on the selected host once. Idle nodes do not guarantee your job can start.

Settings retain socket overrides, partition filters, and the refresh interval across launches; the selected host is never restored. The switch beside the connection status pauses or resumes querying. All visible partitions are selected by default. Your own jobs show expected start times when Slurm provides them; estimates may change or be unavailable.

The default refresh interval is 60 seconds, configurable from 30 seconds to five minutes. Each refresh makes one `sinfo` query and one `squeue` query for all visible jobs, including owner IDs. The same queue response provides pending counts across all partitions and your personal job list, filtered by the remote account’s numeric user ID. Node allocation is refreshed each time because it can change during an SSH connection. There are no per-partition queries or extra polling loops; both commands must be on the remote PATH. Manual refresh, reconnects, and reconfiguration respect a 30-second minimum between query attempts, and manual refresh cannot bypass failure backoff. Failed queries back off automatically, including when settings change while a query is running; results from the old configuration are discarded. Malformed allocation responses are rejected instead of displaying partial counts.

The header buttons and query switch use native macOS tooltips. SlurmBar requests a half-second delay using the undocumented `NSInitialToolTipDelay` preference within the app only; macOS may ignore this hint.

Quit immediately hides the menu bar icon and all app windows, then cancels monitoring in the background. It uses macOS’s standard deferred-termination mechanism, allowing up to two seconds for cleanup and exiting sooner when cleanup finishes. Repeated quit requests do not restart cleanup. Your external SSH connection and Slurm jobs are left untouched.

## Tests and releases

GitHub Actions runs `swift test` on pushes and pull requests. The badge above shows the latest push result on `main`. Tests run locally without a cluster; checking actual monitoring requires your own established SSH connection.

Pushing a tag such as `v0.1.0` runs tests, builds a universal Apple Silicon/Intel app, and publishes a GitHub Release with `SlurmBar.dmg`. To build the same disk image locally:

```sh
./scripts/build-dmg.sh --arch arm64 --arch x86_64
```

Open the DMG and drag SlurmBar from the left onto Applications on the right. The disk image opens in a compact window with an installation arrow. Building the DMG also requires Python 3; the script installs pinned `dmgbuild` tooling in `.build/dmg-tools` on first use (requires network access). Finder automation is not required. The app itself has no third-party dependencies. Builds are ad-hoc signed, without Developer ID signing or notarization.

### First launch

If macOS says Apple cannot check SlurmBar for malicious software, click **Done**, then open **System Settings → Privacy & Security → Open Anyway** and confirm **Open**. Only do this for a copy you trust. macOS saves an exception for the app. See [Apple’s instructions](https://support.apple.com/102445).

[MIT licensed](LICENSE).
