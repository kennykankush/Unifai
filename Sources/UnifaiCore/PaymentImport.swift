import Foundation

/// Imports confirmed payments from CSV, for example a receipt export or a bank statement.
///
/// Header row, case-insensitive, in any order:
///   date (YYYY-MM-DD), description, amount, currency, kind, account, account_label, reference
/// `kind`: subscription, top-up, usage or refund (or the full names shown in the app).
/// `account`: a catalogue service id or name such as "claude-api" or "Claude subscription / Code".
/// `account_label` picks a specific wallet of that service; a missing wallet is created as a manual one.
public enum PaymentImport {
    public struct Row: Equatable {
        public var line: Int
        public var paidAt: Date
        public var description: String
        public var money: Money
        public var kind: PaymentKind
        public var integrationID: String?
        public var accountLabel: String
        public var reference: String
    }

    public struct Summary: Equatable {
        public var imported = 0
        public var duplicates = 0
        /// Automatically recorded renewals superseded by imported receipts.
        public var replaced = 0
        public var createdAccounts: [String] = []
        public init() {}
    }

    public static func parse(_ text: String) throws -> [Row] {
        var lines = records(text)
        guard !lines.isEmpty else { throw ValidationError.message("The file is empty.") }
        let header = lines.removeFirst().map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func column(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let date = column("date"), let amount = column("amount"), let currency = column("currency") else {
            throw ValidationError.message("The header needs at least date, amount and currency columns.")
        }
        let description = column("description"), kind = column("kind"), account = column("account")
        let label = column("account_label"), reference = column("reference")
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX"); dayFormatter.timeZone = .current; dayFormatter.dateFormat = "yyyy-MM-dd"

        var rows: [Row] = []
        for (offset, fields) in lines.enumerated() {
            let line = offset + 2
            func value(_ index: Int?) -> String {
                guard let index, fields.indices.contains(index) else { return "" }
                return fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            guard let day = dayFormatter.date(from: value(date)) else { throw ValidationError.message("Line \(line): use a date like 2025-01-31.") }
            guard let number = Money.parseAmount(value(amount)) else { throw ValidationError.message("Line \(line): enter a positive amount like 20.00.") }
            let code = value(currency).uppercased()
            guard Money.validCurrency(code) else { throw ValidationError.message("Line \(line): \(code.isEmpty ? "currency is missing" : "\(code) is not a currency code").") }
            guard let paymentKind = Self.kind(value(kind)) else { throw ValidationError.message("Line \(line): kind must be subscription, top-up, usage or refund.") }
            var integration: String?
            let accountText = value(account)
            if !accountText.isEmpty {
                guard let match = Catalogue.integrations.first(where: { $0.id.caseInsensitiveCompare(accountText) == .orderedSame || $0.name.caseInsensitiveCompare(accountText) == .orderedSame }) else {
                    throw ValidationError.message("Line \(line): \(accountText) is not a service in the catalogue.")
                }
                integration = match.id
            }
            let name = value(description)
            // Noon local time keeps the calendar day stable across time zones.
            rows.append(Row(line: line, paidAt: day.addingTimeInterval(12 * 3600), description: name.isEmpty ? "Imported payment" : name,
                            money: Money(number, code), kind: paymentKind, integrationID: integration,
                            accountLabel: value(label).isEmpty ? "Personal" : value(label), reference: value(reference)))
        }
        guard !rows.isEmpty else { throw ValidationError.message("The file has a header but no payments.") }
        return rows
    }

    static func kind(_ text: String) -> PaymentKind? {
        switch text.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "", "subscription", "subscription payment": return .subscription
        case "top-up", "topup", "credit top-up", "credits": return .topUp
        case "usage", "settled usage charge": return .usageCharge
        case "refund": return .refund
        default: return nil
        }
    }

    /// RFC 4180 records: quoted fields, escaped quotes, commas and newlines inside quotes.
    static func records(_ text: String) -> [[String]] {
        var records: [[String]] = [], field = "", record: [String] = [], quoted = false
        var iterator = text.replacingOccurrences(of: "\r\n", with: "\n").makeIterator()
        var pending: Character? = nil
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() { if next == "\"" { field.append("\"") } else { quoted = false; pending = next } } else { quoted = false }
                } else { field.append(character) }
            } else {
                switch character {
                case "\"": quoted = true
                case ",": record.append(field); field = ""
                case "\n": record.append(field); records.append(record); record = []; field = ""
                default: field.append(character)
                }
            }
        }
        if !field.isEmpty || !record.isEmpty { record.append(field); records.append(record) }
        return records
    }
}
