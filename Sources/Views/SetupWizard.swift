import SwiftUI

/// First-launch setup wizard.
/// Shown when ~/.snor-oh/setup-done does not exist.
/// Steps: Welcome → Installing → Done.

// MARK: - Setup Model (class for stable reference in async closures)

@Observable
final class SetupModel {
    var step: SetupWizard.Step = .welcome
    var setupLog: [SetupLogEntry] = []
    var error: String?

    struct SetupLogEntry: Identifiable {
        let id = UUID()
        let message: String
    }

    func runSetup() {
        step = .installing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            MCPInstaller.installServer()
            DispatchQueue.main.async { self?.setupLog.append(.init(message: "MCP server installed")) }

            MCPInstaller.installShellHooks()
            DispatchQueue.main.async { self?.setupLog.append(.init(message: "Shell hooks installed")) }

            ClaudeHooks.setup()
            DispatchQueue.main.async { self?.setupLog.append(.init(message: "Claude Code hooks configured")) }

            MCPInstaller.registerServer()
            DispatchQueue.main.async { self?.setupLog.append(.init(message: "MCP server registered")) }

            // Write setup-done marker only if we got here
            let home = FileManager.default.homeDirectoryForCurrentUser
            let marker = home.appendingPathComponent(".snor-oh/setup-done")
            let dir = marker.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: marker.path, contents: nil)

            DispatchQueue.main.async {
                self?.setupLog.append(.init(message: "Setup complete"))
                self?.step = .done
            }
        }
    }
}

// MARK: - Setup Wizard View

struct SetupWizard: View {
    @State private var model = SetupModel()
    let onComplete: () -> Void

    enum Step: Int, CaseIterable {
        case welcome
        case installing
        case done
    }

    var body: some View {
        VStack(spacing: 20) {
            switch model.step {
            case .welcome:
                welcomeView
            case .installing:
                installingView
            case .done:
                doneView
            }
        }
        .frame(width: 420, height: 460)
        .padding(24)
    }

    // MARK: - Welcome

    private var welcomeView: some View {
        VStack(spacing: 18) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 36))
                .foregroundStyle(.blue)

            VStack(spacing: 4) {
                Text("Welcome to snor-oh")
                    .font(.title.bold())
                Text("A desktop companion for your coding sessions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                featureRow(
                    symbol: "pawprint.fill",
                    title: "A mascot that cares",
                    detail: "Pixel pet reacts to your terminals, Claude Code, and when tasks finish."
                )
                featureRow(
                    symbol: "rectangle.stack.fill",
                    title: "Live session panel",
                    detail: "See every open terminal and Claude session — Working… dots tell you what's busy."
                )
                featureRow(
                    symbol: "tray.full.fill",
                    title: "Smart clipboard",
                    detail: "Drag anything onto the mascot. Multi-bucket storage with auto-routing rules."
                )
                featureRow(
                    symbol: "bolt.fill",
                    title: "Quick paste anywhere",
                    detail: "⌘⇧V opens recent items — pick one and it pastes straight into your focused app."
                )
            }
            .frame(maxWidth: 340)

            Spacer(minLength: 4)

            Button("Get Started") {
                model.runSetup()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    /// One feature row: symbol column + title / one-line detail. The symbol
    /// is a fixed-width column so all titles align down the left edge.
    private func featureRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.blue)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Installing

    private var installingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Setting up...")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.setupLog) { entry in
                    Label(entry.message, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("All Set!")
                .font(.title.bold())

            Text("snor-oh is ready. Open a terminal and start coding — your mascot will react to your activity.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Spacer()

            Button("Done") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
