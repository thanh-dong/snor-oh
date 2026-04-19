import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Settings Window

/// Standard macOS settings window with General, Ohh, Claude Code, and About tabs.
struct SettingsView: View {
    let sessionManager: SessionManager
    let spriteEngine: SpriteEngine

    var body: some View {
        TabView {
            GeneralTab(sessionManager: sessionManager)
                .tabItem { Label("General", systemImage: "gearshape") }

            OhhTab(sessionManager: sessionManager, spriteEngine: spriteEngine)
                .tabItem { Label("Ohh", systemImage: "pawprint") }

            BucketTab(manager: BucketManager.shared)
                .tabItem { Label("Bucket", systemImage: "tray.full") }

            ClaudeCodeTab()
                .tabItem { Label("Claude Code", systemImage: "terminal") }

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 560)
    }
}

// MARK: - Bucket Tab

struct BucketTab: View {
    let manager: BucketManager

    @State private var newIgnoreEntry: String = ""

    /// All sliders/toggles bind directly to `manager.settings` via these
    /// computed bindings so the UI stays in sync with any external mutation
    /// (e.g. programmatic `updateSettings`, cross-window changes, disk reload).
    private var captureClipboardBinding: Binding<Bool> {
        Binding(
            get: { manager.settings.captureClipboard },
            set: { new in
                var s = manager.settings
                s.captureClipboard = new
                manager.updateSettings(s)
            }
        )
    }

    private var maxItemsBinding: Binding<Double> {
        Binding(
            get: { Double(manager.settings.maxItems) },
            set: { new in
                var s = manager.settings
                s.maxItems = Int(new)
                manager.updateSettings(s)
            }
        )
    }

    private var maxStorageMBBinding: Binding<Double> {
        Binding(
            get: { Double(manager.settings.maxStorageBytes / 1_000_000) },
            set: { new in
                var s = manager.settings
                s.maxStorageBytes = Int64(new) * 1_000_000
                manager.updateSettings(s)
            }
        )
    }

    var body: some View {
        Form {
            Section("Clipboard Capture") {
                Toggle("Automatically capture clipboard", isOn: captureClipboardBinding)

                if manager.settings.captureClipboard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ignored apps (bundle IDs)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        ForEach(Array(manager.settings.ignoredBundleIDs).sorted(), id: \.self) { bid in
                            HStack {
                                Text(bid)
                                    .font(.system(size: 11, design: .monospaced))
                                Spacer()
                                Button {
                                    var s = manager.settings
                                    s.ignoredBundleIDs.remove(bid)
                                    manager.updateSettings(s)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        HStack {
                            TextField("e.g. com.1password.1password", text: $newIgnoreEntry)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                            Button("Add") {
                                let trimmed = newIgnoreEntry
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty else { return }
                                var s = manager.settings
                                s.ignoredBundleIDs.insert(trimmed)
                                manager.updateSettings(s)
                                newIgnoreEntry = ""
                            }
                        }
                    }
                }
            }

            Section("Capacity") {
                HStack {
                    Text("Max items")
                    Slider(value: maxItemsBinding, in: 50...1000, step: 50)
                    Text("\(manager.settings.maxItems)")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }

                HStack {
                    Text("Max storage")
                    Slider(value: maxStorageMBBinding, in: 10...1000, step: 10)
                    Text("\(manager.settings.maxStorageBytes / 1_000_000) MB")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
            }

            Section("Hotkey") {
                Text("Press **⌃⌥B** to toggle the bucket panel.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    let sessionManager: SessionManager

    @AppStorage(DefaultsKey.theme) private var theme = "dark"
    @AppStorage(DefaultsKey.glowMode) private var glowMode = "off"
    @AppStorage(DefaultsKey.bubbleEnabled) private var bubbleEnabled = true
    @AppStorage(DefaultsKey.panelSize) private var panelSize = "regular"
    @AppStorage(DefaultsKey.hideDock) private var hideDock = false
    @AppStorage(DefaultsKey.trayVisible) private var trayVisible = true
    @AppStorage(DefaultsKey.peerDiscoveryEnabled) private var peerDiscoveryEnabled = true
    @AppStorage(DefaultsKey.marketplaceURL) private var marketplaceURL = DefaultsDefault.marketplaceURL
    @AppStorage(DefaultsKey.creatorName) private var creatorName = ""
    @State private var autoStartEnabled = false
    @State private var autoStartError: String?
    @State private var shellHookConfigured = false
    @State private var mcpInstalled = false
    @State private var mcpRegistered = false
    @State private var mcpInstalling = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("System").tag("system")
                }
                .pickerStyle(.segmented)

                Picker("Glow Effect", selection: $glowMode) {
                    Text("Off").tag("off")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Session Panel") {
                Picker("Card Size", selection: $panelSize) {
                    Text("Compact").tag("compact")
                    Text("Regular").tag("regular")
                    Text("Large").tag("large")
                }
                .pickerStyle(.segmented)
            }

            Section("Behavior") {
                Toggle("Speech Bubbles", isOn: $bubbleEnabled)

                Toggle("Start at Login", isOn: $autoStartEnabled)
                    .onChange(of: autoStartEnabled) { _, enabled in
                        setAutoStart(enabled)
                    }

                Toggle("Hide from Dock", isOn: $hideDock)
                    .onChange(of: hideDock) { _, hide in
                        DispatchQueue.main.async {
                            NSApp.setActivationPolicy(hide ? .accessory : .regular)
                        }
                    }
                    .help("Hides the dock icon. The app remains accessible via the menu bar.")

                Toggle("Show in Menu Bar", isOn: $trayVisible)
                    .help("Shows the pawprint icon in the menu bar.")

                Toggle("Peer Discovery", isOn: $peerDiscoveryEnabled)
                    .help("Advertise on the local network and discover other snor-oh instances for visiting.")
            }

            Section("Marketplace") {
                TextField("URL", text: $marketplaceURL, prompt: Text(DefaultsDefault.marketplaceURL))
                    .textFieldStyle(.roundedBorder)

                TextField("Creator Name", text: $creatorName, prompt: Text("Anonymous"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: creatorName) { _, newVal in
                        if newVal.count > 40 {
                            creatorName = String(newVal.prefix(40))
                        }
                    }

                Text("Used when sharing a custom Ohh to the marketplace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude Code Integration") {
                HStack(spacing: 6) {
                    Image(systemName: shellHookConfigured ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(shellHookConfigured ? .green : .orange)
                        .font(.caption)
                    Text("Shell Hooks")
                    Text(shellHookConfigured ? "configured" : "not sourced in shell config")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: mcpInstalled ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(mcpInstalled ? .green : .red)
                        .font(.caption)
                    Text("MCP Server")
                    Text(mcpInstalled ? "installed" : "not installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: mcpRegistered ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(mcpRegistered ? .green : .red)
                        .font(.caption)
                    Text("Registered in Claude Code")
                    Text(mcpRegistered ? "yes" : "no")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        installMCP()
                    } label: {
                        if mcpInstalling {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(mcpInstalled && mcpRegistered ? "Reinstall" : "Install")
                        }
                    }
                    .disabled(mcpInstalling)

                    if mcpInstalled || mcpRegistered {
                        Button("Uninstall", role: .destructive) {
                            uninstallMCP()
                        }
                        .disabled(mcpInstalling)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            autoStartEnabled = SMAppService.mainApp.status == .enabled
            refreshMCPStatus()
        }
        .alert("Auto-Start Failed", isPresented: .init(
            get: { autoStartError != nil },
            set: { if !$0 { autoStartError = nil } }
        )) {
            Button("OK") { autoStartError = nil }
        } message: {
            Text(autoStartError ?? "")
        }
    }

    private func refreshMCPStatus() {
        mcpInstalled = MCPInstaller.isServerInstalled
        mcpRegistered = MCPInstaller.isRegistered
        shellHookConfigured = checkShellHookConfigured()
    }

    /// Check if terminal-mirror is sourced in any shell config file.
    private func checkShellHookConfigured() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configs = [
            home.appendingPathComponent(".zshrc"),
            home.appendingPathComponent(".bashrc"),
            home.appendingPathComponent(".config/fish/config.fish"),
        ]
        for url in configs {
            if let content = try? String(contentsOf: url, encoding: .utf8),
               content.contains("terminal-mirror") {
                return true
            }
        }
        return false
    }

    private func installMCP() {
        mcpInstalling = true
        DispatchQueue.global(qos: .userInitiated).async {
            MCPInstaller.installServer()
            MCPInstaller.registerServer()
            MCPInstaller.installShellHooks()
            ClaudeHooks.migrate()
            DispatchQueue.main.async {
                mcpInstalling = false
                refreshMCPStatus()
            }
        }
    }

    private func uninstallMCP() {
        mcpInstalling = true
        DispatchQueue.global(qos: .userInitiated).async {
            MCPInstaller.unregisterServer()
            MCPInstaller.uninstallServer()
            DispatchQueue.main.async {
                mcpInstalling = false
                refreshMCPStatus()
            }
        }
    }

    private func setAutoStart(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            autoStartEnabled = !enabled
            autoStartError = error.localizedDescription
        }
    }
}

// MARK: - Ohh Tab

struct OhhTab: View {
    let sessionManager: SessionManager
    let spriteEngine: SpriteEngine

    @AppStorage(DefaultsKey.nickname) private var nickname = "Buddy"
    @AppStorage(DefaultsKey.displayScale) private var displayScale = 1.0
    @AppStorage(DefaultsKey.pet) private var selectedPet = "sprite"

    @AppStorage(DefaultsKey.marketplaceURL) private var marketplaceURL = DefaultsDefault.marketplaceURL
    @AppStorage(DefaultsKey.creatorName) private var creatorName = ""

    @State private var editingNickname = ""
    @State private var nicknameChanged = false
    @State private var showSmartImport = false
    @State private var isSharing = false
    @State private var sharingName: String = ""

    private static let snorohType = UTType(filenameExtension: "snoroh") ?? .data
    private static let animimeType = UTType(filenameExtension: "animime") ?? .data

    var body: some View {
        Form {
            Section("Identity") {
                HStack {
                    TextField("Nickname", text: $editingNickname)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .onChange(of: editingNickname) { _, newVal in
                            nicknameChanged = newVal != nickname
                        }

                    Button("Save") {
                        let trimmed = String(editingNickname.prefix(20))
                        nickname = trimmed
                        editingNickname = trimmed
                        nicknameChanged = false
                        sessionManager.nickname = trimmed
                    }
                    .disabled(!nicknameChanged)
                }
            }

            Section("Display Size") {
                Picker("Scale", selection: $displayScale) {
                    Text("Tiny (0.5x)").tag(0.5)
                    Text("Normal (1x)").tag(1.0)
                    Text("Large (1.5x)").tag(1.5)
                    Text("XL (2x)").tag(2.0)
                }
                .pickerStyle(.segmented)
            }

            Section("Pet") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                    ForEach(SpriteConfig.builtInPets, id: \.self) { pet in
                        PetCard(
                            petID: pet,
                            name: pet.capitalized,
                            isSelected: selectedPet == pet
                        ) {
                            selectedPet = pet
                            sessionManager.pet = pet
                        }
                    }

                    ForEach(CustomOhhManager.shared.ohhs) { ohh in
                        PetCard(
                            petID: ohh.id,
                            name: ohh.name,
                            isSelected: selectedPet == ohh.id
                        ) {
                            selectedPet = ohh.id
                            sessionManager.pet = ohh.id
                        }
                    }
                }
            }

            Section("Custom Ohhs") {
                HStack {
                    Button("Smart Import") {
                        showSmartImport = true
                    }

                    Button("Import Package") {
                        importSnorohFile()
                    }
                    .help("Import .snoroh or .animime package")

                    Spacer()

                    if !CustomOhhManager.shared.ohhs.isEmpty {
                        Menu("Manage") {
                            ForEach(CustomOhhManager.shared.ohhs) { ohh in
                                Menu(ohh.name) {
                                    Button("Share to Marketplace…") { shareOhh(ohh.id) }
                                    Button("Export") { exportOhh(ohh.id) }
                                    Button("Delete", role: .destructive) { deleteOhh(ohh.id) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            editingNickname = nickname
        }
        .sheet(isPresented: $showSmartImport) {
            SmartImportSheet()
        }
        .sheet(isPresented: $isSharing) {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Sharing \"\(sharingName)\" to marketplace…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(width: 320)
        }
    }

    private func importSnorohFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.snorohType, Self.animimeType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try OhhExporter.importOhh(from: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func exportOhh(_ id: String) {
        guard let ohh = CustomOhhManager.shared.ohh(withID: id) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = OhhExporter.defaultFilename(for: ohh)
        panel.allowedContentTypes = [Self.snorohType]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try OhhExporter.export(ohhID: id, to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func shareOhh(_ id: String) {
        guard let ohh = CustomOhhManager.shared.ohh(withID: id) else { return }

        let baseURL = marketplaceURL.trimmingCharacters(in: .whitespaces).isEmpty
            ? DefaultsDefault.marketplaceURL
            : marketplaceURL
        let creator = creatorName.trimmingCharacters(in: .whitespaces)
        let creatorArg: String? = creator.isEmpty ? nil : creator
        let filename = OhhExporter.defaultFilename(for: ohh)

        let data: Data
        do {
            data = try OhhExporter.exportData(ohhID: id)
        } catch {
            presentShareAlert(
                title: "Share Failed",
                message: error.localizedDescription,
                style: .warning
            )
            return
        }

        sharingName = ohh.name
        isSharing = true

        Task {
            do {
                let result = try await MarketplaceClient.upload(
                    data: data,
                    filename: filename,
                    creator: creatorArg,
                    baseURL: baseURL
                )
                await MainActor.run {
                    isSharing = false
                    presentShareSuccess(name: ohh.name, result: result)
                }
            } catch {
                await MainActor.run {
                    isSharing = false
                    presentShareAlert(
                        title: "Share Failed",
                        message: error.localizedDescription,
                        style: .warning
                    )
                }
            }
        }
    }

    private func presentShareSuccess(name: String, result: MarketplaceClient.UploadResult) {
        let alert = NSAlert()
        alert.messageText = "Shared \"\(name)\" to marketplace"
        var info = "Package ID: \(result.id)"
        if let remaining = result.remaining {
            info += "\nDaily uploads remaining: \(remaining)"
        }
        alert.informativeText = info
        alert.alertStyle = .informational

        if result.packageURL != nil {
            alert.addButton(withTitle: "Copy Link")
        }
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        if result.packageURL != nil, response == .alertFirstButtonReturn, let url = result.packageURL {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }

    private func presentShareAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }

    private func deleteOhh(_ id: String) {
        let alert = NSAlert()
        alert.messageText = "Delete this custom ohh?"
        alert.informativeText = "This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if selectedPet == id {
            let defaultPet = SpriteConfig.builtInPets.first ?? "sprite"
            selectedPet = defaultPet
            sessionManager.pet = defaultPet
        }

        CustomOhhManager.shared.deleteOhh(id: id)
        SpriteCache.shared.purgeCustomPet(id)
    }
}

// MARK: - Pet Card

struct PetCard: View {
    let petID: String
    let name: String
    let isSelected: Bool
    let action: () -> Void

    @State private var previewFrame: CGImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if let frame = previewFrame {
                        Image(decorative: frame, scale: 1.0, orientation: .up)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "pawprint.fill")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 64)

                Text(name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(8)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .onAppear {
            let frames = SpriteCache.shared.frames(pet: petID, status: .idle)
            previewFrame = frames.first
        }
    }
}

// MARK: - About Tab

struct AboutTab: View {
    @AppStorage(DefaultsKey.devMode) private var devMode = false
    @State private var versionClickCount = 0

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "pawprint.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("snor-oh")
                .font(.title.bold())

            Text("Version \(version) (\(build))\(devMode ? " [DEV]" : "")")
                .font(.callout)
                .foregroundStyle(.secondary)
                .onTapGesture {
                    versionClickCount += 1
                    if versionClickCount >= 10 {
                        devMode.toggle()
                        versionClickCount = 0
                    }
                }

            Text("A desktop mascot that reacts to your terminal and Claude Code activity.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Divider()
                .frame(width: 200)

            HStack(spacing: 20) {
                Link("GitHub", destination: URL(string: "https://github.com/thanh-dong/snor-oh")!)
                    .font(.callout)
            }

            Spacer()
        }
        .padding()
    }
}
