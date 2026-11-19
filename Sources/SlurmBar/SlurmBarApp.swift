import SwiftUI
import AppKit
import SlurmBarCore

private let configurationURL = URL(string: "https://github.com/KoniHD/SlurmBar#ssh-setup")!

@MainActor
private enum AppBrand {
    static let icon: NSImage = {
        let image = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "server.rack", accessibilityDescription: "SlurmBar")!
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

@main
struct SlurmBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var model: AppModel { appDelegate.model }

    init() {
        // AppKit's undocumented delay hint is in milliseconds. Register it for
        // this process only; macOS still controls native tooltip presentation.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])
    }

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { !appDelegate.quitCoordinator.isQuitting },
            set: { _ in }
        )) {
            DashboardView(model: model, updater: appDelegate.updater, settingsWindow: appDelegate.settingsWindow)
        } label: {
            MenuBarLabel(title: model.menuTitle, runningJobCount: model.menuRunningJobCount)
        }
        .menuBarExtraStyle(.window)
        Window("SlurmBar Settings", id: "settings") {
            HostSettingsView(model: model, updater: appDelegate.updater)
                .background(SettingsWindowAccessor(controller: appDelegate.settingsWindow))
        }
        .defaultSize(width: 600, height: 500)
    }
}

struct DashboardView: View {
    @Bindable var model: AppModel
    let updater: UpdateController
    let settingsWindow: SettingsWindowController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Label {
                    Text("SlurmBar")
                } icon: {
                    Image(nsImage: AppBrand.icon).resizable().frame(width: 24, height: 24)
                }.font(.headline)
                Spacer()
                Button { model.requestRefresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh when due (minimum 30 seconds)").accessibilityLabel("Refresh")
                    .disabled(model.selectedHost == nil)
                Button { settingsWindow.open(openWindow) } label: { Image(systemName: "gearshape") }
                    .help("Settings").accessibilityLabel("Settings")
                Button {
                    NSApplication.shared.terminate(nil)
                } label: { Image(systemName: "power") }
                    .help("Quit").accessibilityLabel("Quit")
            }
            if let release = updater.availableRelease {
                UpdateBanner(release: release, updater: updater)
            }
            Picker("Host", selection: $model.selectedAlias) {
                Text("Select a host…").tag("")
                ForEach(model.discoveries) { item in Text(item.alias).tag(item.alias) }
            }
            .task { await model.reloadDiscoveries() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.selectedAlias.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "network").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                            Text("No host currently selected").font(.headline)
                            Text("Connect with SSH, then select a host above.")
                                .foregroundStyle(.secondary)
                            Link("Help with configuration", destination: configurationURL)
                        }
                        .font(.callout).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.vertical, 56)
                    } else if let host = model.selectedHost {
                        HostCard(host: host, model: model)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Configure \(model.selectedAlias)").font(.headline)
                            Text(model.selectedDiscovery?.resolutionIssue ?? "Set the existing ControlMaster socket path in Settings.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Configure host…") { settingsWindow.open(openWindow) }
                            Link("Help with configuration", destination: configurationURL).font(.callout)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            // An explicit ideal height keeps MenuBarExtra's scroll area from collapsing.
            }.frame(minHeight: 240, idealHeight: 420, maxHeight: 560)
        }.padding(18).frame(width: 420)
    }
}

struct UpdateBanner: View {
    let release: UpdateRelease
    let updater: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                Text("SlurmBar \(release.version.description) is available").font(.callout.weight(.semibold))
                Spacer(minLength: 4)
                if updater.isInstalling {
                    ProgressView().controlSize(.small)
                } else if updater.canInstall {
                    Button("Install & Restart") { Task { await updater.installAvailableUpdate() } }
                        .disabled(updater.isBusy)
                } else {
                    Link("Download", destination: release.notesURL)
                }
            }
            if let message = updater.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Link("Release notes", destination: release.notesURL).font(.caption)
        }
        .padding(10)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct HostCard: View {
    let host: SSHHost
    let model: AppModel
    private var showsInlineSnapshotAge: Bool {
        model.activeHosts.contains(host.id) && model.statuses[host.id] == "Connected"
            && model.snapshots[host.id] != nil
    }

    private func snapshotAge(_ snapshot: ClusterSnapshot) -> some View {
        HStack(spacing: 3) {
            Text(model.isSnapshotCurrent(host.id) ? "Updated" : "Last snapshot · stale")
            Text(snapshot.updatedAt, style: .relative)
            Text("ago")
        }.foregroundStyle(.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(model.activeHosts.contains(host.id) ? .green : .gray).frame(width: 7, height: 7)
                if showsInlineSnapshotAge, let snapshot = model.snapshots[host.id] {
                    snapshotAge(snapshot).font(.caption)
                } else {
                    Text(model.statuses[host.id] ?? "Waiting for SSH").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 4)
                Toggle("Query host", isOn: Binding(get: { model.selectedHost?.enabled ?? false }, set: { value in
                    if let i = model.hosts.firstIndex(where: { $0.id == host.id }) { model.hosts[i].enabled = value }
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .help(host.enabled ? "Stop querying" : "Resume querying")
            }
            if let snapshot = model.snapshots[host.id] {
                if !showsInlineSnapshotAge {
                    snapshotAge(snapshot).font(.caption2)
                }
                ForEach(snapshot.partitions) { partition in
                    PartitionBar(partition: partition, runningJobCount: snapshot.runningJobCount(in: partition.name))
                }
                if snapshot.partitions.isEmpty { Text("No visible partitions match your selection.").font(.caption) }
                if let warning = snapshot.jobsWarning { Text(warning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if let warning = snapshot.pendingWarning { Text(warning).font(.caption).foregroundStyle(.secondary) }
                if !snapshot.jobs.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text("Your jobs").font(.subheadline.bold())
                    ForEach(snapshot.jobs) { job in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(job.id) · \(job.name)").font(.caption.bold())
                            Text("\(job.partition) · \(job.state) · \(job.reason)").font(.caption).foregroundStyle(.secondary)
                            if job.state.uppercased().contains("PENDING") {
                                Text("Estimated start: \(job.expectedStart.isEmpty ? "unavailable" : job.expectedStart)").font(.caption).foregroundStyle(.secondary)
                            }
                        }.textSelection(.enabled)
                    }
                }
            }
        }
    }
}

struct PartitionBar: View {
    let partition: PartitionSnapshot
    var runningJobCount: Int = 0
    private var segments: [(category: NodeCategory, count: Int, color: Color)] {
        [(.idle, partition.idle, .green), (.mixed, partition.mixed, .orange),
         (.allocated, partition.allocated, .red), (.unavailable, partition.unavailable, .gray)]
    }
    private var summary: String {
        guard !partition.nodes.isEmpty else { return "No nodes" }
        return segments.map { segment in
            let percentage = Double(segment.count) / Double(partition.nodes.count) * 100
            return "\(segment.category.rawValue.capitalized): \(segment.count) nodes (\(percentage.formatted(.number.precision(.fractionLength(1))))%)"
        }.joined(separator: "\n") + "\n" + pendingSummary
            + (runningJobCount > 0 ? "\nYour running jobs: \(runningJobCount)." : "")
    }
    private var pendingSummary: String {
        let count = partition.pendingJobs.map { "\($0) pending" } ?? "Pending unavailable"
        return count + ". Visible queue entries; array tasks are grouped. Jobs requesting multiple partitions count in each."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(partition.name).font(.subheadline.weight(.semibold))
                Spacer()
                if runningJobCount > 0 {
                    Text("\(runningJobCount) running")
                        .font(.caption).foregroundStyle(.green)
                }
                Text(partition.pendingJobs.map { "\($0) pending" } ?? "Pending unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(segments.filter { $0.count > 0 }, id: \.category) { segment in
                        let fraction = Double(segment.count) / Double(max(1, partition.nodes.count))
                        Rectangle().fill(segment.color.gradient)
                            .overlay {
                                if fraction >= 0.10 {
                                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.black.opacity(0.8))
                                }
                            }
                            .frame(width: geometry.size.width * fraction)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }.frame(height: 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(partition.name)
        .accessibilityValue(summary)
        .instantHelp(summary)
    }
}

struct HostSettingsView: View {
    @Bindable var model: AppModel
    @Bindable var updater: UpdateController
    @State private var alias = ""
    @State private var path = ""
    @State private var partitionDraft = ""
    @State private var detectionIssue: String?
    @State private var saved = false
    /// The socket path last loaded or saved for `alias`; only a different path is saved.
    @State private var savedPath = ""
    @State private var detectionRequest: UUID?
    @State private var reloadRequest = UUID()
    @FocusState private var pathFocused: Bool
    /// Folders scanned for sockets; a folder picked in the panel is added to `~/.ssh`.
    @State private var socketFolders = ControlSocketScanner.defaultDirectories
    @State private var socketCandidates: [String] = []
    private var configuredHost: SSHHost? { model.hosts.first { $0.alias == alias } }
    var body: some View {
        Form {
            Section("Configure host") {
                Picker("SSH alias", selection: $alias) {
                    Text("Select a host…").tag("")
                    ForEach(model.discoveries) { item in Text(item.alias).tag(item.alias) }
                }.onChange(of: alias) { previous, _ in
                    // A path typed for the previous host is kept, not discarded.
                    savePath(alias: previous)
                    detectionRequest = nil
                    loadConfiguration()
                    rescanSockets()
                }
                TextField("Existing ControlPath (socket)", text: $path, prompt: Text("Absolute path or ~/…"))
                    .focused($pathFocused)
                    .onSubmit { savePath() }
                    .onChange(of: pathFocused) { _, focused in if !focused { savePath() } }
                    .onChange(of: path) { _, _ in saved = false }
                HStack {
                    Button("Reload SSH hosts") { reloadRequest = UUID() }
                    Button("Detect control path") {
                        detectionRequest = UUID()
                    }.disabled(alias.isEmpty || detectionRequest != nil)
                    Menu("Choose socket") {
                        // NSOpenPanel never lists sockets, so the menu offers the sockets found by scanning.
                        if socketCandidates.isEmpty {
                            Text("No sockets found in \(socketFolders.map(displayPath).joined(separator: ", "))")
                        }
                        ForEach(socketCandidates, id: \.self) { candidate in
                            // A dot marks the socket currently in the path field; others are indented to match.
                            Button((isCurrentSocket(candidate) ? "•  " : "    ") + displayPath(candidate)) { choose(candidate) }
                        }
                        Divider()
                        Button("Search another folder…") { chooseSocketFolder() }
                        Button("Rescan") { rescanSockets() }
                    }.fixedSize().disabled(alias.isEmpty)
                    if saved { Text("Saved").font(.caption).foregroundStyle(.secondary) }
                }
                if let issue = detectionIssue {
                    Text(issue).font(.caption).foregroundStyle(.secondary)
                }
                Text("Hosts with ControlMaster enabled in SSH configuration appear automatically. Choose socket lists sockets you own in ~/.ssh and any folder you search. A socket path you detect, choose, or enter is saved as soon as it changes.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("SSH configuration guide", destination: configurationURL)
            }
            if let host = configuredHost, let names = model.partitionNames[host.id.uuidString] {
                Section("Partitions for \(alias)") {
                    TextField("Partitions", text: $partitionDraft, prompt: Text("All partitions"))
                        .onSubmit { model.updatePartitions(partitionDraft, hostID: host.id) }
                    Button("Save partitions") { model.updatePartitions(partitionDraft, hostID: host.id) }
                    Text("Enter one partition, or several separated by commas (for example: \(names.count >= 2 ? names.prefix(2).joined(separator: ", ") : "gpu, cpu")). Leave empty to show all partitions.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Available: " + names.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updater.automaticChecks)
                HStack {
                    Button("Check now") { Task { await updater.checkNow() } }.disabled(updater.isBusy)
                    if updater.isChecking { ProgressView().controlSize(.small) }
                    if let release = updater.availableRelease, updater.canInstall {
                        Button("Install \(release.version.description) & Restart") {
                            Task { await updater.installAvailableUpdate() }
                        }.disabled(updater.isBusy)
                    }
                }
                if let message = updater.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text("Version \(updater.currentVersion?.description ?? "unknown"). Update checks contact GitHub only, and installs are verified against a signing key built into the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Refresh") {
                Picker("Interval", selection: $model.refreshInterval) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
                Text("Monitoring requires an external active session and SSH channel inspection support. Closing your external sessions pauses polling. Snapshots over one hour old are cleared and the host selection resets if no usable session is detected.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding().frame(minWidth: 540, minHeight: 460)
            .onAppear { alias = model.selectedAlias; loadConfiguration(); rescanSockets() }
            .task(id: reloadRequest) { await model.reloadDiscoveries() }
            .task(id: detectionRequest) {
                guard detectionRequest != nil else { return }
                let requestedAlias = alias
                let originalPath = path
                let found = await HostDiscovery.resolveInBackground(alias: requestedAlias)
                guard !Task.isCancelled, alias == requestedAlias else { return }
                detectionRequest = nil
                // A slow lookup must not replace a socket path edited meanwhile.
                guard path == originalPath else { return }
                path = found.controlPath ?? ""
                detectionIssue = found.resolutionIssue
                savePath()
            }
            .onDisappear { savePath() }
    }
    private func choose(_ socket: String) {
        path = socket
        detectionIssue = nil
        savePath()
    }
    private func rescanSockets() {
        socketCandidates = ControlSocketScanner.sockets(in: socketFolders)
    }
    /// The open panel picks a folder; sockets inside it (which the panel cannot show) are listed in the menu.
    private func chooseSocketFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = "Search Folder"
        panel.message = "Choose the folder that contains the ControlPath socket."
        panel.directoryURL = socketFolders.last
        guard panel.runModal() == .OK, let folder = panel.url?.standardizedFileURL else { return }
        if !socketFolders.contains(folder) { socketFolders.append(folder) }
        rescanSockets()
        let inFolder = ControlSocketScanner.sockets(in: [folder])
        if inFolder.count == 1 {
            choose(inFolder[0])
        } else {
            detectionIssue = inFolder.isEmpty
                ? "No sockets owned by you were found in \(displayPath(folder.path))."
                : "Found \(inFolder.count) sockets in \(displayPath(folder.path)); pick one from Choose socket."
        }
    }
    private func displayPath(_ url: URL) -> String { displayPath(url.path) }
    private func displayPath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
    private func isCurrentSocket(_ candidate: String) -> Bool {
        let current = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return false }
        func canonical(_ value: String) -> String {
            URL(fileURLWithPath: (value as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        }
        return canonical(current) == canonical(candidate)
    }
    private func loadConfiguration() {
        let found = model.discoveries.first { $0.alias == alias }
        path = configuredHost?.controlPath ?? found?.controlPath ?? ""
        detectionIssue = configuredHost == nil ? found?.resolutionIssue : nil
        partitionDraft = configuredHost?.selectedPartitions.joined(separator: ", ") ?? ""
        savedPath = path
        saved = false
    }
    /// Saving clears the host's snapshot, so it happens on commit and only for a changed, valid path.
    private func savePath(alias target: String? = nil) {
        let target = target ?? alias
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, trimmed != savedPath.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") else { return }
        model.configure(alias: target, path: trimmed)
        savedPath = path
        if target == alias { saved = true }
    }
}
