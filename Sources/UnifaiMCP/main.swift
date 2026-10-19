import Foundation
import UnifaiCore

// Unifai MCP server: newline-delimited JSON-RPC 2.0 over stdio.
// Read-only. Each call re-reads state.json, so answers follow the app's latest saved readings.
// It never opens Keychain, never makes network requests and never writes.

let serverVersion = "0.1.0"
let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]

func dataDirectory() -> URL {
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--data-directory"), args.indices.contains(index + 1) {
        return URL(fileURLWithPath: (args[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
    }
    if let path = ProcessInfo.processInfo.environment["UNIFAI_DATA_DIR"], !path.isEmpty {
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Unifai", isDirectory: true)
}

let repository = StateRepository(directory: dataDirectory())

struct ToolError: Error { let message: String }

let tools: [[String: Any]] = [
    [
        "name": "get_overview",
        "title": "AI spending overview",
        "description": "Start here. Summarises the user's AI accounts: remaining credit per account and currency, ChatGPT and Claude plans, Codex usage windows, OpenAI API spend, total money paid, renewals due in the next 30 days, and accounts whose readings are stale or failed. Values are the last readings saved by the Unifai app.",
        "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        "annotations": ["readOnlyHint": true, "openWorldHint": false]
    ],
    [
        "name": "get_balances",
        "title": "Account balances",
        "description": "Per-account wallet readings: remaining credit (OpenRouter, DeepSeek, Codex credits), provider-reported spend (OpenAI API, last 30 days), the subscription plan (ChatGPT, Claude) and usage windows such as Codex's 5-hour and weekly limits with percent used and reset time. Includes when each reading was observed and whether it is stale. Never sum across accounts or currencies.",
        "inputSchema": [
            "type": "object",
            "properties": ["provider": ["type": "string", "description": "Optional filter matched against provider id or name, account label or billing owner, e.g. \"openrouter\", \"deepseek\", \"work\"."]],
            "additionalProperties": false
        ],
        "annotations": ["readOnlyHint": true, "openWorldHint": false]
    ],
    [
        "name": "get_spending",
        "title": "Money paid",
        "description": "Confirmed payments the user recorded from receipts (top-ups, subscription charges, settled usage, refunds), with totals per currency and the period the history covers.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "since": ["type": "string", "description": "Optional ISO 8601 date (YYYY-MM-DD). Only payments on or after this date."],
                "limit": ["type": "integer", "minimum": 0, "maximum": 200, "description": "Maximum payments to list, newest first. Default 20."]
            ],
            "additionalProperties": false
        ],
        "annotations": ["readOnlyHint": true, "openWorldHint": false]
    ],
    [
        "name": "get_renewals",
        "title": "Subscription renewals",
        "description": "Expected subscription renewals (for example ChatGPT, Claude or Cursor plans) with amount, cadence and days until the next charge. These are expectations, not payments.",
        "inputSchema": [
            "type": "object",
            "properties": ["within_days": ["type": "integer", "minimum": 0, "description": "Optional. Only renewals due within this many days (overdue ones included)."]],
            "additionalProperties": false
        ],
        "annotations": ["readOnlyHint": true, "openWorldHint": false]
    ]
]

func parseDate(_ text: String) -> Date? {
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = .current; day.dateFormat = "yyyy-MM-dd"
    if let date = day.date(from: text) { return date }
    return ISO8601DateFormatter().date(from: text)
}

func callTool(_ name: String, _ arguments: [String: Any]) throws -> Data {
    let state: PersistentState
    do { state = try repository.load() }
    catch { throw ToolError(message: "Could not read Unifai data at \(repository.file.path): \(error.localizedDescription)") }
    let encoder = AgentReport.encoder()
    switch name {
    case "get_overview":
        return try encoder.encode(AgentReport.overview(state, rates: RateStore(directory: repository.directory).load()))
    case "get_balances":
        return try encoder.encode(AgentReport.balances(state, provider: arguments["provider"] as? String))
    case "get_spending":
        var since: Date?
        if let text = arguments["since"] as? String {
            guard let date = parseDate(text) else { throw ToolError(message: "since must be a date like 2026-10-01.") }
            since = date
        }
        let limit = min(200, max(0, (arguments["limit"] as? NSNumber)?.intValue ?? 20))
        return try encoder.encode(AgentReport.spending(state, since: since, limit: limit, rates: RateStore(directory: repository.directory).load()))
    case "get_renewals":
        return try encoder.encode(AgentReport.renewals(state, withinDays: (arguments["within_days"] as? NSNumber)?.intValue))
    default:
        throw ToolError(message: "Unknown tool: \(name)")
    }
}

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

func reply(_ id: Any, result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func fail(_ id: Any, code: Int, message: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }

func handle(_ message: [String: Any]) {
    let method = message["method"] as? String
    guard let id = message["id"], !(id is NSNull) else { return } // Notifications need no reply.
    let params = message["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        let requested = params["protocolVersion"] as? String ?? supportedProtocols[0]
        reply(id, result: [
            "protocolVersion": supportedProtocols.contains(requested) ? requested : supportedProtocols[0],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "unifai", "title": "Unifai", "version": serverVersion],
            "instructions": "Read-only access to the user's AI account balances, recorded payments and subscription renewals from the Unifai Mac app. Call get_overview first. Readings are only as fresh as the app's last refresh; check observedAt and stale. Never add credit remaining, money paid and expected renewals together, and never combine currencies."
        ])
    case "ping":
        reply(id, result: [:])
    case "tools/list":
        reply(id, result: ["tools": tools])
    case "tools/call":
        guard let name = params["name"] as? String else { return fail(id, code: -32602, message: "Missing tool name.") }
        guard tools.contains(where: { $0["name"] as? String == name }) else { return fail(id, code: -32602, message: "Unknown tool: \(name)") }
        do {
            let data = try callTool(name, params["arguments"] as? [String: Any] ?? [:])
            var result: [String: Any] = ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": false]
            if let structured = try? JSONSerialization.jsonObject(with: data) {
                result["structuredContent"] = structured is [Any] ? ["items": structured] : structured
            }
            reply(id, result: result)
        } catch let error as ToolError {
            reply(id, result: ["content": [["type": "text", "text": error.message]], "isError": true])
        } catch {
            reply(id, result: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
        }
    default:
        fail(id, code: -32601, message: "Method not found: \(method ?? "")")
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    guard let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else {
        send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); continue
    }
    if let batch = json as? [[String: Any]] { batch.forEach(handle) }
    else if let message = json as? [String: Any] { handle(message) }
}
