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

## What the display means

- **Green / idle:** available, idle CPUs.
- **Orange / mixed:** partially allocated.
- **Red / allocated:** fully allocated.
- **Gray / unavailable:** down, drained, reserved, maintenance, or otherwise unavailable.

These colors describe scheduler allocation, not measured CPU/GPU utilization. Each partition has a proportional bar showing the percentage of nodes in each state. Hover over it for counts and percentages. Each partition also shows its visible pending queue entries; array tasks remain grouped as in `squeue`, and jobs requesting multiple partitions count in each. Counts reflect your account’s job visibility, so cluster privacy settings may hide other users’ jobs. Failed queue queries show “Pending unavailable” rather than zero. Nodes can belong to multiple partitions; the menu bar total counts each node on the selected host once. Idle nodes do not guarantee your job can start.

Settings retain socket overrides, partition filters, and the refresh interval across launches; the selected host is never restored. The switch beside the connection status pauses or resumes querying. All visible partitions are selected by default. Your own jobs show expected start times when Slurm provides them; estimates may change or be unavailable.

The default refresh interval is 60 seconds, configurable from 30 seconds to five minutes. Each refresh makes one `sinfo` query and one `squeue` query for all visible jobs, including owner IDs. The same queue response provides pending counts across all partitions and your personal job list, filtered by the remote account’s numeric user ID. Node allocation is refreshed each time because it can change during an SSH connection. There are no per-partition queries or extra polling loops; both commands must be on the remote PATH. Manual refresh, reconnects, and reconfiguration respect a 30-second minimum between query attempts, and manual refresh cannot bypass failure backoff. Failed queries back off automatically.

## Tests and releases

GitHub Actions runs `swift test` on pushes and pull requests. The badge above shows the latest push result on `main`. Tests run locally without a cluster; checking actual monitoring requires your own established SSH connection.

Pushing a tag such as `v0.1.0` runs tests, builds a universal Apple Silicon/Intel app, and publishes a GitHub Release with `SlurmBar.dmg`. To build the same disk image locally:

```sh
./scripts/build-dmg.sh --arch arm64 --arch x86_64
```

Open the DMG and drag SlurmBar into Applications. Builds are ad-hoc signed, without Developer ID signing or notarization.

[MIT licensed](LICENSE).
