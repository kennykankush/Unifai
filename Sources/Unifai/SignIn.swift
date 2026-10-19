import AppKit
import UnifaiCore

/// Sign-in for connections whose apps own the login: ChatGPT through Codex, Claude through Claude Code.
/// Unifai starts each tool's official flow and never handles the resulting token.
@MainActor enum SignIn {
    static func supports(_ integrationID: String) -> Bool { ["codex", "claude-subscription", "azure-subscription"].contains(integrationID) }
    static func title(_ integrationID: String) -> String {
        switch integrationID {
        case "codex": return "Sign in with ChatGPT"
        case "azure-subscription": return "Sign in with Azure"
        default: return "Sign in with Claude"
        }
    }

    /// Codex: runs its browser sign-in and returns when Codex reports success.
    /// Claude Code: opens Terminal running `claude auth login`, which needs its own interactive prompt.
    static func start(_ integrationID: String) async throws {
        if AppRuntime.fixtureMode { throw ValidationError.message("Sign-in is disabled in the synthetic workspace.") }
        switch integrationID {
        case "codex":
            try await CodexClient().signIn(openURL: { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } })
        case "claude-subscription":
            guard let claude = ClaudeCodeClient.locate() else {
                throw ValidationError.message("Claude Code is not installed. Install it from claude.com/claude-code, then sign in.")
            }
            try openTerminal(running: claude, ["auth", "login"], named: "Sign in to Claude", wallet: "Claude")
        case "azure-subscription":
            guard let az = AzureCostClient.locate() else {
                throw ValidationError.message("The Azure CLI is not installed. Install it with brew install azure-cli, then sign in.")
            }
            try openTerminal(running: az, ["login"], named: "Sign in to Azure", wallet: "Azure")
        default:
            throw ValidationError.message("This connection does not have a sign-in flow.")
        }
    }

    /// Opens Terminal running a tool's own interactive sign-in, for CLIs that need a prompt.
    private static func openTerminal(running tool: URL, _ arguments: [String], named name: String, wallet: String) throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).command")
        let quote = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = ([tool.path] + arguments).map(quote).joined(separator: " ")
        let body = "#!/bin/zsh -l\n\(command)\necho\necho 'Finished. Close this window and click Refresh on the \(wallet) wallet in Unifai.'\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }
}
