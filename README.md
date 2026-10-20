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

In SlurmBar Settings, select an SSH alias. SlurmBar resolves its configured ControlPath locally, including `~/.ssh/master-%C`; you do not need to replace an existing ControlMaster setup with the example above. Socket paths are resolved even before a connection exists. For a manually entered alias, use **Detect control path**. For a host already saved with an incorrect path, use **Detect control path from SSH configuration** in its Settings entry. **Reload SSH hosts** rereads configuration after changes.

Discovery reads SSH configuration as data. It honors supported Host patterns, first-value-wins defaults, and ordered Include files, and expands control-path tokens without invoking SSH or evaluating commands. Unsupported conditional settings (such as Match exec or hostname canonicalization) show a reason and require a manual expanded socket path. A socket file picker remains available. No SSH configuration is modified.

Connect with your normal client. If VS Code uses a different SSH binary or configuration file, ensure it creates the same control socket. SlurmBar will not initiate a test connection.

## Monitoring

Monitoring starts only when the selected ControlMaster has an active external shell, command, or forwarding channel. A persistent master alone does not activate it. The SSH client and master must support `-O channels`; unsupported implementations pause monitoring.

SlurmBar validates the socket and prevents SSH from falling back to a new connection. It never closes your external master or modifies your SSH configuration.

## What the display means

- **Green / idle:** available, idle CPUs.
- **Orange / mixed:** partially allocated.
- **Red / allocated:** fully allocated.
- **Gray / unavailable:** down, drained, reserved, maintenance, or otherwise unavailable.

These colors describe scheduler allocation, not measured CPU/GPU utilization. CPU counts appear in node tooltips. Nodes can belong to multiple partitions; the menu bar total deduplicates host/node pairs. Idle nodes do not guarantee your job can start.

Settings retain your selected hosts, sockets, partitions, and refresh interval across launches. All visible partitions are selected by default. Your own jobs show expected start times when Slurm provides them.

The default refresh interval is 60 seconds, configurable from 30 seconds to five minutes. The remote environment must provide `sinfo` and `squeue` on PATH. See [monitoring behavior](docs/monitoring.md) for connection checks, allocation details, job estimates, and polling limits.

## Development

See [development and validation](docs/development.md) for test coverage, end-to-end checks, and the CI template.

[MIT licensed](LICENSE).
