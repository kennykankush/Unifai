import AppKit
import UnifaiCore

/// Sign-in for connections whose apps own the login: ChatGPT through Codex, Claude through Claude Code.
/// Unifai starts each tool's official flow and never handles the resulting token.
@MainActor enum SignIn {
    static func supports(_ integrationID: String) -> Bool { integrationID == "codex" || integrationID == "claude-subscription" }
    static func title(_ integrationID: String) -> String { integrationID == "codex" ? "Sign in with ChatGPT" : "Sign in with Claude" }

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
            let script = FileManager.default.temporaryDirectory.appendingPathComponent("Sign in to Claude.command")
            let quoted = "'" + claude.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let body = "#!/bin/zsh -l\n\(quoted) auth login\necho\necho 'Finished. Close this window and click Refresh on the Claude wallet in Unifai.'\n"
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        default:
            throw ValidationError.message("This connection does not have a sign-in flow.")
        }
    }
}
