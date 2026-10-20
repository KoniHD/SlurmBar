# SlurmBar

A native SwiftUI macOS menu bar app that shows Slurm node allocation **only while an external SSH session is active**. SlurmBar reuses your existing OpenSSH ControlMaster socket. It never creates a server connection or prompts for credentials.

## Build and run

Requires macOS 14+ and a Swift 6 toolchain (Xcode or Command Line Tools). No third-party packages or remote installation.

```sh
swift test
./scripts/build-app.sh
open dist/SlurmBar.app
```

The script creates a locally ad-hoc-signed app. It is not Developer ID signed or notarized. Start at login by adding the built app under System Settings → General → Login Items, if desired.

## SSH setup (you apply this yourself)

SlurmBar never edits `~/.ssh/config`. You need a multiplex master created by another client, such as Terminal or VS Code Remote SSH, and the exact path of its control socket. An ordinary SSH connection without a ControlMaster cannot be reused.

For example, create a private socket directory yourself:

```sh
mkdir -p ~/.ssh/slurmbar
chmod 700 ~/.ssh/slurmbar
```

Add settings to your existing host block yourself. Replace the example alias and absolute path. Keep the socket path below 104 bytes. SSH uses the first matching value for most settings, so ensure these settings precede conflicting defaults.

```sshconfig
Host example-cluster
    # Keep your existing HostName, User, ProxyJump and authentication settings.
    ControlMaster auto
    ControlPath ~/.ssh/slurmbar/%n
    ControlPersist 60
```

In SlurmBar Settings, select or enter `example-cluster` and enter `~/.ssh/slurmbar/example-cluster`. Suggested socket paths are conventions, not detected configuration. For an existing hashed `%C` configuration, enter the actual expanded socket filename. A socket file picker is provided. Aliases are suggestions read from literal `Host` entries and literal `Include` files; wildcard hosts/includes and conditional directives are not evaluated. Enter aliases manually when necessary.

Connect with your normal client. If VS Code uses a different SSH binary or configuration file, ensure it creates the same control socket. SlurmBar will not initiate a test connection.

## Activation and strict connection reuse

The installed `/usr/bin/ssh` **and the master process** need OpenSSH's `-O channels` / info-request support. Older implementations pause monitoring rather than guessing from a socket or process name. Run `ssh -V` locally to check your client version; capability detection is authoritative.

Before each Slurm query, SlurmBar inspects channels through the local control socket. It requires an open `session` or `direct-tcpip` channel. These cover shell/command sessions and active forwarding streams used by clients such as VS Code. Control clients, listening sockets, and a persistent master alone do not activate it. Detection measures active SSH channels, not whether a particular application window is visible. A VS Code connection may remain active after its window closes if its SSH channel remains open.

Every operation runs SSH with an explicit validated socket, `-F /dev/null`, `ControlMaster=no`, and `ProxyCommand=/usr/bin/false`. If the master disappears or rejects a session, fallback fails locally instead of connecting. User SSH configuration is never executed by monitoring; this avoids `Match exec`, `LocalCommand`, jump-host and authentication side effects. The alias is a label; the chosen socket determines the remote server/account. Only your own socket in a directory you own that is not writable by others is accepted.

Channel checks run about every five seconds while idle. Queries are serialized and bounded to eight seconds. If the external client closes during an in-flight query, that short query may finish or reach its timeout; no further Slurm query starts without a fresh external-channel check. The app never closes the externally owned master, sends SSH keepalives, or runs a remote `watch`. There is no background remote agent.

## What the display means

- **Green / idle:** Slurm reports idle CPUs on an available node without a reservation or unavailable state flag.
- **Orange / mixed:** partially allocated.
- **Red / allocated:** fully allocated according to Slurm.
- **Gray / unavailable:** down, drained, reserved, maintenance, powered down, flagged, unknown, or unavailable partition.

These are scheduler allocation states, not measured CPU/GPU utilization. CPU allocation counts appear in node tooltips. Per-partition counts may overlap because a node can belong to several partitions. The menu bar total deduplicates host/node pairs. Idle nodes do not guarantee your job can start.

Visible partitions are discovered with `sinfo`. Visibility does not establish account/QOS eligibility. All visible partitions are selected by default; save a comma-separated subset in Settings. Empty selection means all visible partitions. Host, socket, enabled state, refresh interval and partition preferences persist locally via UserDefaults; private connection information is never embedded in source code or uploaded. Partition names are cached locally across launches. Snapshots are kept in memory and labeled with their update age, including after disconnection.

Your own jobs are queried with `squeue`. Pending jobs show Slurm's expected start when available; estimates depend on backfill configuration and may change or be unavailable. There is no generic per-partition wait prediction. If job information is restricted or unavailable, the app retains node information and displays a job-query warning.

Default refresh is 60 seconds, configurable from 30 seconds to five minutes. Each snapshot performs one `sinfo` query and one own-user `squeue` query on the selected login host, with exponential backoff after failures. Local channel inspection does not query the Slurm controller. Respect your site's monitoring policy and use a longer interval for large clusters. The remote non-interactive environment must provide `sinfo` and `squeue` on PATH. No submission, cancellation, privileged operation, or hidden-partition discovery is performed.

## Development and validation

```sh
swift test
swift build -c release
```

Tests cover channel classification, connection arguments, socket validation, malformed responses, node flags, partition overlap, and job estimates. A ready-to-enable GitHub Actions template at `docs/github-actions.yml` builds, tests and packages on macOS. Copy it to `.github/workflows/swift.yml` using credentials with workflow permission or the GitHub web editor. The initial publication credentials do not have that permission. Unit tests do not require remote access. A real ControlMaster/VS Code/Slurm end-to-end check must be performed with your own established connection; it is not implied by passing parser tests.

## References

- [OpenSSH multiplexing and ControlPersist](https://man.openbsd.org/ssh_config#ControlMaster)
- [OpenSSH control commands](https://man.openbsd.org/ssh#O)
- [Slurm sinfo and node states](https://slurm.schedmd.com/sinfo.html)
- [Slurm expected start times](https://slurm.schedmd.com/squeue.html#OPT_start)
- [Slurm access controls](https://slurm.schedmd.com/slurm.conf.html#OPT_PrivateData)

MIT licensed.
