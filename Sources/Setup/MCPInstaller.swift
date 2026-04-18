import Foundation

/// Installs the MCP server to ~/.snor-oh/mcp/ and registers it in ~/.claude.json.
enum MCPInstaller {

    /// Copy server.mjs from the app bundle to ~/.snor-oh/mcp/.
    /// Called on every startup to keep the server up-to-date.
    static func installServer() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let mcpDir = home.appendingPathComponent(".snor-oh/mcp")

        // Create directory
        do {
            try FileManager.default.createDirectory(at: mcpDir, withIntermediateDirectories: true)
        } catch {
            print("[mcp] failed to create \(mcpDir.path): \(error)")
            return
        }

        // Find bundled server.mjs
        guard let sourceURL = findBundledServer() else {
            print("[mcp] server.mjs not found in bundle")
            return
        }

        let destURL = mcpDir.appendingPathComponent("server.mjs")

        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                // Atomic replace: copy to temp, then swap in one syscall
                let tmpURL = mcpDir.appendingPathComponent("server.mjs.tmp")
                try? FileManager.default.removeItem(at: tmpURL)
                try FileManager.default.copyItem(at: sourceURL, to: tmpURL)
                _ = try FileManager.default.replaceItem(
                    at: destURL,
                    withItemAt: tmpURL,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly,
                    resultingItemURL: nil
                )
            } else {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            }
            print("[mcp] installed server to \(destURL.path)")
        } catch {
            print("[mcp] failed to copy server: \(error)")
        }
    }

    /// Register the MCP server in ~/.claude.json so Claude Code discovers it.
    /// Does not overwrite existing registrations.
    static func registerServer() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let serverPath = home.appendingPathComponent(".snor-oh/mcp/server.mjs").path

        guard FileManager.default.fileExists(atPath: serverPath) else {
            print("[mcp] server not installed, skipping registration")
            return
        }

        let configURL = home.appendingPathComponent(".claude.json")

        // Load or create config — bail if file exists but can't be parsed
        var config: [String: Any]
        if FileManager.default.fileExists(atPath: configURL.path) {
            guard let data = try? Data(contentsOf: configURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[mcp] could not parse ~/.claude.json — skipping registration to avoid data loss")
                return
            }
            config = json
        } else {
            config = [:]
        }

        // Get or create mcpServers
        var servers = config["mcpServers"] as? [String: Any] ?? [:]

        // Don't overwrite existing registration
        if servers["snor-oh"] != nil {
            print("[mcp] already registered in \(configURL.path)")
            return
        }

        servers["snor-oh"] = [
            "command": "node",
            "args": [serverPath]
        ]
        config["mcpServers"] = servers

        // Write back
        do {
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configURL, options: .atomic)
            print("[mcp] registered in \(configURL.path)")
        } catch {
            print("[mcp] failed to write config: \(error)")
        }
    }

    /// Copy terminal-mirror shell scripts from the app bundle to ~/.snor-oh/scripts/.
    /// Called on every startup to keep scripts up-to-date.
    static func installShellHooks() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let scriptsDir = home.appendingPathComponent(".snor-oh/scripts")

        do {
            try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        } catch {
            print("[setup] failed to create \(scriptsDir.path): \(error)")
            return
        }

        let shells = ["zsh", "bash", "fish"]
        var installed = 0
        for shell in shells {
            let filename = "terminal-mirror.\(shell)"
            guard let sourceURL = findBundledScript(filename) else {
                print("[setup] \(filename) not found in bundle")
                continue
            }
            let destURL = scriptsDir.appendingPathComponent(filename)
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    // Atomic replace: copy to temp, then swap
                    let tmpURL = scriptsDir.appendingPathComponent("\(filename).tmp")
                    try? FileManager.default.removeItem(at: tmpURL)
                    try FileManager.default.copyItem(at: sourceURL, to: tmpURL)
                    _ = try FileManager.default.replaceItem(
                        at: destURL,
                        withItemAt: tmpURL,
                        backupItemName: nil,
                        options: .usingNewMetadataOnly,
                        resultingItemURL: nil
                    )
                } else {
                    try FileManager.default.copyItem(at: sourceURL, to: destURL)
                }
                installed += 1
            } catch {
                print("[setup] failed to install \(filename): \(error)")
            }
        }
        if installed > 0 {
            print("[setup] shell hooks installed to \(scriptsDir.path) (\(installed)/\(shells.count))")
        }
    }

    // MARK: - Uninstall

    /// Remove the MCP server files from ~/.snor-oh/mcp/.
    static func uninstallServer() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let mcpDir = home.appendingPathComponent(".snor-oh/mcp")
        let serverFile = mcpDir.appendingPathComponent("server.mjs")
        if FileManager.default.fileExists(atPath: serverFile.path) {
            try? FileManager.default.removeItem(at: serverFile)
            print("[mcp] removed server from \(serverFile.path)")
        }
    }

    /// Remove the snor-oh entry from ~/.claude.json mcpServers.
    static func unregisterServer() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".claude.json")

        guard FileManager.default.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var servers = config["mcpServers"] as? [String: Any],
              servers["snor-oh"] != nil else {
            return
        }

        servers.removeValue(forKey: "snor-oh")
        config["mcpServers"] = servers

        if let jsonData = try? JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? jsonData.write(to: configURL, options: .atomic)
            print("[mcp] unregistered from \(configURL.path)")
        }
    }

    // MARK: - Status

    static var isServerInstalled: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".snor-oh/mcp/server.mjs").path
        )
    }

    static var isRegistered: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else {
            return false
        }
        return servers["snor-oh"] != nil
    }

    // MARK: - Private

    private static func findBundledScript(_ filename: String) -> URL? {
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        // SPM bundles Resources/Scripts/ as "Scripts" subdirectory
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Scripts") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        return nil
    }

    private static func findBundledServer() -> URL? {
        // SPM bundles resources into the bundle
        if let url = Bundle.main.url(forResource: "server", withExtension: "mjs", subdirectory: "mcp-server") {
            return url
        }
        // Fallback: search bundle root
        if let url = Bundle.main.url(forResource: "server", withExtension: "mjs") {
            return url
        }
        return nil
    }
}
