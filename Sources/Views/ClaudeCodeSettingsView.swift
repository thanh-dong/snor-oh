import SwiftUI

// MARK: - Claude Code Tab

struct ClaudeCodeTab: View {
    @State private var config = ClaudeCodeConfigManager()
    @State private var section: CCSection = .plugins

    enum CCSection: String, CaseIterable {
        case plugins = "Plugins"
        case skills = "Skills"
        case commands = "Commands"
        case mcp = "MCP"
        case hooks = "Hooks"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $section) {
                    ForEach(CCSection.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button(action: { config.loadAll() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload configuration")
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            switch section {
            case .plugins: PluginsSectionView(config: config)
            case .skills: SkillsSectionView(config: config)
            case .commands: CommandsSectionView(config: config)
            case .mcp: MCPSectionView(config: config)
            case .hooks: HooksSectionView(config: config)
            }
        }
        .onAppear { config.loadAll() }
    }
}

// MARK: - Plugins Section

private struct PluginsSectionView: View {
    let config: ClaudeCodeConfigManager
    @State private var expandedSkills: Set<String> = []

    var body: some View {
        if config.plugins.isEmpty {
            ccEmptyState("No Plugins Installed", icon: "puzzlepiece.extension")
        } else {
            List(config.plugins) { plugin in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.name).fontWeight(.medium)
                            HStack(spacing: 6) {
                                if !plugin.marketplace.isEmpty {
                                    Text("@\(plugin.marketplace)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text("v\(plugin.version)")
                                    .font(.caption2)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(.secondary.opacity(0.1))
                                    .cornerRadius(3)
                                if !plugin.installedAt.isEmpty {
                                    Text(formatDate(plugin.installedAt))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { plugin.isEnabled },
                            set: { _ in config.togglePlugin(plugin) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }

                    if !plugin.skills.isEmpty {
                        let isExpanded = expandedSkills.contains(plugin.id)
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if isExpanded {
                                    expandedSkills.remove(plugin.id)
                                } else {
                                    expandedSkills.insert(plugin.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                Text("\(plugin.skills.count) skill\(plugin.skills.count == 1 ? "" : "s")")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        if isExpanded {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 90))],
                                alignment: .leading, spacing: 4
                            ) {
                                ForEach(plugin.skills, id: \.self) { skill in
                                    Text(skill)
                                        .font(.caption2.monospaced())
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.secondary.opacity(0.08))
                                        .cornerRadius(4)
                                }
                            }
                            .padding(.leading, 16)
                        }
                    }
                }
                .contextMenu {
                    if !plugin.installPath.isEmpty {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(
                                nil, inFileViewerRootedAtPath: plugin.installPath
                            )
                        }
                    }
                }
            }
        }
    }

    private func formatDate(_ iso: String) -> String {
        let fmt = ISO8601DateFormatter()
        guard let date = fmt.date(from: iso) else { return "" }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df.string(from: date)
    }
}

// MARK: - Skills Section

private struct SkillsSectionView: View {
    let config: ClaudeCodeConfigManager
    @State private var deleteTarget: ClaudeSkill?
    @State private var searchText = ""

    private var filtered: [ClaudeSkill] {
        if searchText.isEmpty { return config.skills }
        return config.skills.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        if config.skills.isEmpty {
            ccEmptyState("No Standalone Skills", icon: "wand.and.stars")
        } else {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter skills...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Divider()

                List(filtered) { skill in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(skill.name).fontWeight(.medium)
                            if skill.isSymlink {
                                Image(systemName: "link")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help("Symlink (from plugin)")
                            }
                        }
                        if !skill.description.isEmpty {
                            Text(skill.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(
                                nil, inFileViewerRootedAtPath: skill.path.path
                            )
                        }
                        Button("Open SKILL.md") {
                            NSWorkspace.shared.open(
                                skill.path.appendingPathComponent("SKILL.md")
                            )
                        }
                        Divider()
                        Button("Delete", role: .destructive) { deleteTarget = skill }
                    }
                }
            }
            .alert("Delete Skill?", isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )) {
                Button("Cancel", role: .cancel) { deleteTarget = nil }
                Button("Delete", role: .destructive) {
                    if let t = deleteTarget { config.deleteSkill(t) }
                    deleteTarget = nil
                }
            } message: {
                Text("Delete \"\(deleteTarget?.name ?? "")\"? This cannot be undone.")
            }
        }
    }
}

// MARK: - Commands Section

private struct CommandsSectionView: View {
    let config: ClaudeCodeConfigManager
    @State private var deleteTarget: ClaudeCommand?
    @State private var expandedCommand: String?
    @State private var commandContent: String?

    var body: some View {
        if config.commands.isEmpty {
            ccEmptyState("No Commands Found", icon: "terminal")
        } else {
            List(config.commands) { command in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("/\(command.name)")
                                .fontWeight(.medium)
                                .font(.body.monospaced())
                            if !command.description.isEmpty {
                                Text(command.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(expandedCommand == command.id ? nil : 1)
                            }
                        }
                        Spacer()
                        Button {
                            toggleExpand(command)
                        } label: {
                            Image(systemName: expandedCommand == command.id
                                  ? "chevron.up" : "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Preview content")
                    }

                    if expandedCommand == command.id, let content = commandContent {
                        ScrollView {
                            Text(content)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 150)
                        .padding(8)
                        .background(.secondary.opacity(0.05))
                        .cornerRadius(6)
                    }
                }
                .contextMenu {
                    Button("Open in Editor") {
                        NSWorkspace.shared.open(command.path)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(
                            command.path.path,
                            inFileViewerRootedAtPath: command.path
                                .deletingLastPathComponent().path
                        )
                    }
                    Divider()
                    Button("Delete", role: .destructive) { deleteTarget = command }
                }
            }
            .alert("Delete Command?", isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )) {
                Button("Cancel", role: .cancel) { deleteTarget = nil }
                Button("Delete", role: .destructive) {
                    if let t = deleteTarget { config.deleteCommand(t) }
                    deleteTarget = nil
                }
            } message: {
                Text("Delete \"/\(deleteTarget?.name ?? "")\"? This cannot be undone.")
            }
        }
    }

    private func toggleExpand(_ command: ClaudeCommand) {
        if expandedCommand == command.id {
            expandedCommand = nil
            commandContent = nil
        } else {
            expandedCommand = command.id
            commandContent = config.commandContent(for: command)
        }
    }
}

// MARK: - MCP Section

private struct MCPSectionView: View {
    let config: ClaudeCodeConfigManager
    @State private var showAddSheet = false
    @State private var deleteTarget: ClaudeMCPServer?
    @State private var deleteProjectPath: String?

    private var isEmpty: Bool {
        config.mcpServers.isEmpty && config.projectMCPServers.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if isEmpty {
                ccEmptyState("No MCP Servers", icon: "server.rack")
            } else {
                List {
                    if !config.mcpServers.isEmpty {
                        Section("Global") {
                            ForEach(config.mcpServers) { server in
                                mcpRow(server, project: nil)
                                    .contextMenu { mcpContextMenu(server, project: nil) }
                            }
                        }
                    }

                    ForEach(config.projectMCPServers) { group in
                        Section {
                            ForEach(group.servers) { server in
                                mcpRow(server, project: group.projectPath)
                                    .contextMenu {
                                        mcpContextMenu(server, project: group.projectPath)
                                    }
                            }
                        } header: {
                            Text(group.projectName)
                                .help(group.projectPath)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button { showAddSheet = true } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddMCPSheet(config: config)
        }
        .alert("Remove MCP Server?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                deleteTarget = nil; deleteProjectPath = nil
            }
            Button("Remove", role: .destructive) {
                if let t = deleteTarget {
                    config.removeMCPServer(t, projectPath: deleteProjectPath)
                }
                deleteTarget = nil; deleteProjectPath = nil
            }
        } message: {
            Text("Remove \"\(deleteTarget?.name ?? "")\"?")
        }
    }

    @ViewBuilder
    private func mcpContextMenu(_ server: ClaudeMCPServer, project: String?) -> some View {
        if let cmd = server.command {
            Button("Copy Command") {
                let full = ([cmd] + server.args).joined(separator: " ")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(full, forType: .string)
            }
        }
        Divider()
        Button("Remove", role: .destructive) {
            deleteTarget = server
            deleteProjectPath = project
        }
    }

    private func mcpRow(_ server: ClaudeMCPServer, project: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.name).fontWeight(.medium)
                    Text(server.serverType)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(server.serverType == "http"
                                    ? Color.purple.opacity(0.15)
                                    : Color.teal.opacity(0.15))
                        .cornerRadius(3)
                }
                if let cmd = server.command {
                    let display = ([cmd] + server.args).joined(separator: " ")
                    Text(display)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let url = server.url {
                    Text(url)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !server.env.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(server.env.keys.sorted().prefix(3)), id: \.self) { key in
                            Text(key)
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.secondary.opacity(0.08))
                                .cornerRadius(3)
                        }
                        if server.env.count > 3 {
                            Text("+\(server.env.count - 3)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Spacer()
            Button {
                deleteTarget = server
                deleteProjectPath = project
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
    }
}

// MARK: - Hooks Section

private struct HooksSectionView: View {
    let config: ClaudeCodeConfigManager
    @State private var showAddSheet = false
    @State private var deleteTarget: ClaudeHookEntry?
    @State private var expandedHook: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if config.hooks.isEmpty {
                ccEmptyState("No Hooks Configured", icon: "link.badge.plus")
            } else {
                List {
                    ForEach(config.hookEvents, id: \.event) { group in
                        Section {
                            ForEach(group.hooks) { hook in
                                hookRow(hook)
                            }
                        } header: {
                            HStack {
                                Text(group.event)
                                    .font(.caption.monospaced().weight(.semibold))
                                Spacer()
                                Text("\(group.hooks.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button { showAddSheet = true } label: {
                    Label("Add Hook", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddHookSheet(config: config)
        }
        .alert("Remove Hook?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Remove", role: .destructive) {
                if let t = deleteTarget { config.removeHook(t) }
                deleteTarget = nil
            }
        } message: {
            Text("Remove this hook?")
        }
    }

    private func hookRow(_ hook: ClaudeHookEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Badges row
            HStack(spacing: 6) {
                if !hook.matcher.isEmpty {
                    Text(hook.matcher)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.orange.opacity(0.15))
                        .cornerRadius(3)
                }
                if hook.isAsync {
                    Text("async")
                        .font(.caption2)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.green.opacity(0.15))
                        .cornerRadius(3)
                }
                if let t = hook.timeout {
                    Text("\(t)s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if config.isOwnHook(hook) {
                    Text("snor-oh")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.blue.opacity(0.15))
                        .cornerRadius(3)
                } else {
                    Button { deleteTarget = hook } label: {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove hook")
                }
            }

            // Friendly label
            Text(config.hookLabel(hook))
                .font(.callout)

            // Expandable raw command
            if expandedHook == hook.id {
                Text(hook.command)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.05))
                    .cornerRadius(4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedHook = expandedHook == hook.id ? nil : hook.id
            }
        }
    }
}

// MARK: - Add MCP Sheet

private struct AddMCPSheet: View {
    let config: ClaudeCodeConfigManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var serverType = "stdio"
    @State private var command = ""
    @State private var args = ""
    @State private var url = ""
    @State private var envText = ""
    @State private var target = "global"

    private var isValid: Bool {
        !name.isEmpty
        && (serverType == "stdio" ? !command.isEmpty : !url.isEmpty)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Add MCP Server").font(.headline)

            Form {
                TextField("Server Name", text: $name)

                Picker("Type", selection: $serverType) {
                    Text("stdio").tag("stdio")
                    Text("HTTP").tag("http")
                }
                .pickerStyle(.segmented)

                if serverType == "stdio" {
                    TextField("Command (e.g. npx)", text: $command)
                    TextField("Args (space-separated)", text: $args)
                    TextField("Env vars (KEY=VALUE, one per line)", text: $envText,
                              axis: .vertical)
                        .lineLimit(2...4)
                } else {
                    TextField("URL", text: $url)
                }

                Picker("Save to", selection: $target) {
                    Text("~/.claude.json").tag("global")
                    Text("~/.claude/settings.json").tag("settings")
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { addServer() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private func addServer() {
        var serverConfig: [String: Any]
        if serverType == "stdio" {
            serverConfig = ["command": command]
            let argList = args.split(separator: " ").map(String.init)
            if !argList.isEmpty { serverConfig["args"] = argList }
            let env = parseEnv(envText)
            if !env.isEmpty { serverConfig["env"] = env }
        } else {
            serverConfig = ["type": "http", "url": url]
        }
        config.addMCPServer(name: name, config: serverConfig, target: target)
        dismiss()
    }

    private func parseEnv(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let idx = trimmed.firstIndex(of: "=") else { continue }
            env[String(trimmed[..<idx])] = String(trimmed[trimmed.index(after: idx)...])
        }
        return env
    }
}

// MARK: - Add Hook Sheet

private struct AddHookSheet: View {
    let config: ClaudeCodeConfigManager
    @Environment(\.dismiss) private var dismiss

    @State private var event = "PreToolUse"
    @State private var matcher = ""
    @State private var command = ""
    @State private var timeoutText = ""
    @State private var isAsync = false
    @State private var statusMessage = ""

    private static let events = [
        "PreToolUse", "PostToolUse", "SessionStart",
        "SessionEnd", "UserPromptSubmit", "Stop",
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Hook").font(.headline)

            Form {
                Picker("Event", selection: $event) {
                    ForEach(Self.events, id: \.self) { Text($0) }
                }

                TextField("Matcher (regex, optional)", text: $matcher)
                TextField("Command", text: $command)
                TextField("Timeout seconds (optional)", text: $timeoutText)
                TextField("Status Message (optional)", text: $statusMessage)
                Toggle("Async", isOn: $isAsync)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { addHook() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(command.isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private func addHook() {
        config.addHook(
            event: event,
            matcher: matcher,
            command: command,
            timeout: Int(timeoutText),
            isAsync: isAsync,
            statusMessage: statusMessage.isEmpty ? nil : statusMessage
        )
        dismiss()
    }
}

// MARK: - Empty State Helper

private func ccEmptyState(_ title: String, icon: String) -> some View {
    VStack(spacing: 8) {
        Spacer()
        Image(systemName: icon)
            .font(.system(size: 32))
            .foregroundStyle(.quaternary)
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
