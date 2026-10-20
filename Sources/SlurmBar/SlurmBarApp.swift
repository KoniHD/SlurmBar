import SwiftUI
import AppKit
import SlurmBarCore

@main
struct SlurmBarApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        MenuBarExtra(model.menuTitle, systemImage: "server.rack") {
            DashboardView(model: model)
        }
        .menuBarExtraStyle(.window)
        Window("SlurmBar Settings", id: "settings") {
            HostSettingsView(model: model)
        }
        .defaultSize(width: 600, height: 500)
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("SlurmBar", systemImage: "server.rack").font(.headline)
                Spacer()
                Button { model.requestRefresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh when due (minimum 30 seconds)")
                Button { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "gearshape") }.help("Host settings")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.hosts.isEmpty {
                        ContentUnavailableView("Choose SSH hosts", systemImage: "server.rack", description: Text("Add an SSH alias and its existing ControlMaster socket in Settings."))
                    }
                    ForEach(model.hosts) { host in
                        HostCard(host: host, model: model)
                    }
                }
            }.frame(maxHeight: 560)
            Divider()
            HStack {
                Text("Uses existing SSH sessions only").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }.padding().frame(width: 460)
    }
}

struct HostCard: View {
    let host: SSHHost
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(model.activeHosts.contains(host.id) ? .green : .gray).frame(width: 8, height: 8)
                Text(host.alias).font(.headline)
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { model.hosts.first(where: { $0.id == host.id })?.enabled ?? false }, set: { value in
                    if let i = model.hosts.firstIndex(where: { $0.id == host.id }) { model.hosts[i].enabled = value }
                })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            Text(model.statuses[host.id] ?? "Waiting for SSH").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let snapshot = model.snapshots[host.id] {
                HStack {
                    Text(model.isSnapshotCurrent(host.id) ? "Updated" : "Last snapshot · stale")
                    Text(snapshot.updatedAt, style: .relative)
                    Text("ago")
                }.font(.caption2).foregroundStyle(.secondary)
                ForEach(snapshot.partitions) { partition in
                    DisclosureGroup {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92))], alignment: .leading) {
                            ForEach(partition.nodes) { node in
                                HStack(spacing: 4) {
                                    Circle().fill(color(node.category)).frame(width: 7, height: 7)
                                    Text(node.name).font(.caption.monospaced()).lineLimit(1)
                                }
                                .help("\(node.name): \(node.state) · \(node.allocatedCPUs)/\(node.totalCPUs) CPUs allocated")
                                .accessibilityLabel("\(node.name), \(node.state), \(node.allocatedCPUs) of \(node.totalCPUs) CPUs allocated")
                            }
                        }.padding(.vertical, 4)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(partition.name).font(.subheadline.bold())
                            Text(summary(partition)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if snapshot.partitions.isEmpty { Text("No visible partitions match your selection.").font(.caption) }
                if let warning = snapshot.jobsWarning { Text(warning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if !snapshot.jobs.isEmpty {
                    Text("Your jobs").font(.subheadline.bold()).padding(.top, 4)
                    ForEach(snapshot.jobs) { job in
                        VStack(alignment: .leading, spacing: 2) {
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
    private func summary(_ partition: PartitionSnapshot) -> String {
        let nodes = partition.nodes
        return "\(nodes.filter { $0.category == .idle }.count) idle · \(nodes.filter { $0.category == .mixed }.count) mixed · \(nodes.filter { $0.category == .allocated }.count) allocated · \(nodes.filter { $0.category == .unavailable }.count) unavailable"
    }
    private func color(_ category: NodeCategory) -> Color {
        switch category { case .idle: .green; case .mixed: .orange; case .allocated: .red; case .unavailable: .gray }
    }
}

struct HostSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var alias = ""
    @State private var path = ""
    @State private var partitionDrafts: [UUID: String] = [:]
    var body: some View {
        Form {
            Section("Hosts") {
                ForEach(model.hosts) { host in
                    VStack(alignment: .leading) {
                        HStack {
                            Text(host.alias).bold()
                            Spacer()
                            Button("Remove", role: .destructive) { model.remove(host.id) }
                        }
                        Text(host.controlPath).font(.caption.monospaced()).textSelection(.enabled)
                        if let names = model.partitionNames[host.id.uuidString] {
                            Text("Visible partitions (visibility does not confirm submission eligibility)").font(.caption).foregroundStyle(.secondary)
                            TextField("All partitions, or comma-separated names", text: Binding(get: { partitionDrafts[host.id] ?? host.selectedPartitions.joined(separator: ", ") }, set: { partitionDrafts[host.id] = $0 }))
                                .onSubmit { model.updatePartitions(partitionDrafts[host.id] ?? host.selectedPartitions.joined(separator: ", "), hostID: host.id) }
                            Button("Save partitions") { model.updatePartitions(partitionDrafts[host.id] ?? host.selectedPartitions.joined(separator: ", "), hostID: host.id) }
                            Text("Discovered: " + names.joined(separator: ", ")).font(.caption)
                        }
                    }
                }
            }
            Section("Add host") {
                Picker("SSH alias", selection: $alias) {
                    Text("Choose or enter below").tag("")
                    ForEach(model.discoveries) { item in Text(item.alias).tag(item.alias) }
                }.onChange(of: alias) { _, value in
                    if let item = model.discoveries.first(where: { $0.alias == value }) { path = item.suggestedControlPath }
                }
                TextField("Alias", text: $alias)
                TextField("Existing ControlPath (absolute path or ~/…)", text: $path)
                Button("Choose socket…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.showsHiddenFiles = true
                    panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
                Text("The suggested path is a convention, not a discovered socket. Enter the exact ControlPath used by your SSH client. SlurmBar never edits SSH configuration.").font(.caption).foregroundStyle(.secondary)
                Button("Add host") { model.add(alias: alias, path: path) }
                    .disabled(!HostDiscovery.isSafeAlias(alias) || path.isEmpty)
            }
            Section("Refresh") {
                Picker("Interval", selection: $model.refreshInterval) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
                Text("Monitoring requires an external active session and SSH channel inspection support. Closing your external sessions pauses polling. Cached snapshots remain labeled with their age.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding().frame(minWidth: 540, minHeight: 460)
    }
}
