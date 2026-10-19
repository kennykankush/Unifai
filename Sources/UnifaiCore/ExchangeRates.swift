import Foundation

/// Daily European Central Bank reference rates, used only to show spending in one display currency.
/// Recorded payments always keep their original amount and currency; conversions are labelled
/// as approximate because a card issuer's rate can differ from the reference rate.
public struct RateTable: Codable, Equatable {
    /// "yyyy-MM-dd" -> currency -> units of that currency per 1 EUR.
    public var rates: [String: [String: Double]]
    public var fetchedAt: Date
    public var currencies: [String]
    public init(rates: [String: [String: Double]], fetchedAt: Date, currencies: [String]) {
        self.rates = rates; self.fetchedAt = fetchedAt; self.currencies = currencies
    }

    public static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Units per EUR on the date, falling back to the latest earlier publication (weekends, holidays),
    /// or the earliest available rate for dates before the table starts.
    public func perEuro(_ currency: String, on date: Date) -> Double? {
        if currency == "EUR" { return 1 }
        var day = date
        for _ in 0..<10 {
            if let value = rates[Self.dayFormatter.string(from: day)]?[currency] { return value }
            day = day.addingTimeInterval(-86400)
        }
        let key = Self.dayFormatter.string(from: date)
        let available = rates.keys.sorted()
        let candidate = available.last(where: { $0 <= key && rates[$0]?[currency] != nil }) ?? available.first(where: { rates[$0]?[currency] != nil })
        return candidate.flatMap { rates[$0]?[currency] }
    }

    public func convert(_ money: Money, to target: String, on date: Date) -> Money? {
        if money.currency == target { return money }
        guard let from = perEuro(money.currency, on: date), let to = perEuro(target, on: date), from > 0 else { return nil }
        let value = NSDecimalNumber(decimal: money.amount).doubleValue / from * to
        return Money(Decimal(string: String(format: "%.2f", value)) ?? Decimal(value), target)
    }

    public func covers(_ currency: String) -> Bool { currency == "EUR" || currencies.contains(currency) }
}

public enum ExchangeRates {
    public static let source = URL(string: "https://data.ecb.europa.eu/methodology/exchange-rates")!

    /// Fetches daily reference rates for the given ISO currencies since `start` from the ECB data API.
    public static func fetch(currencies: [String], since start: Date, now: Date = .now, session: URLSession = BalanceClient.privateSession()) async throws -> RateTable {
        let wanted = Set(currencies.map { $0.uppercased() }.filter { $0 != "EUR" && Money.validCurrency($0) }).sorted()
        guard !wanted.isEmpty else { return RateTable(rates: [:], fetchedAt: now, currencies: []) }
        let from = RateTable.dayFormatter.string(from: start.addingTimeInterval(-14 * 86400))
        let url = URL(string: "https://data-api.ecb.europa.eu/service/data/EXR/D.\(wanted.joined(separator: "+")).EUR.SP00.A?startPeriod=\(from)&format=csvdata&detail=dataonly")!
        var request = URLRequest(url: url)
        request.setValue("text/csv", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectorError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ConnectorError.unavailable(http.statusCode) }
        return try parse(String(decoding: data, as: UTF8.self), currencies: wanted, now: now)
    }

    public static func parse(_ csv: String, currencies: [String], now: Date = .now) throws -> RateTable {
        let records = PaymentImport.records(csv)
        guard let header = records.first, let currency = header.firstIndex(of: "CURRENCY"),
              let period = header.firstIndex(of: "TIME_PERIOD"), let value = header.firstIndex(of: "OBS_VALUE") else { throw ConnectorError.invalidResponse }
        var rates: [String: [String: Double]] = [:]
        for row in records.dropFirst() where row.count > max(currency, period, value) {
            guard let number = Double(row[value]), number > 0 else { continue }
            rates[row[period], default: [:]][row[currency]] = number
        }
        guard !rates.isEmpty else { throw ConnectorError.invalidResponse }
        return RateTable(rates: rates, fetchedAt: now, currencies: currencies)
    }
}

public struct RateStore {
    public let file: URL
    public init(directory: URL) { file = directory.appendingPathComponent("exchange-rates.json") }
    public func load() -> RateTable? { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(RateTable.self, from: $0) } }
    public func save(_ table: RateTable) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(table).write(to: file, options: .atomic)
    }
}

public extension PersistentState {
    /// Payments re-expressed in one currency using rates on each payment's date. Payments in a
    /// currency the table cannot convert are returned in `unconverted`.
    func payments(in target: String, rates: RateTable) -> (converted: [PaymentRecord], unconverted: [PaymentRecord]) {
        var converted: [PaymentRecord] = [], unconverted: [PaymentRecord] = []
        for payment in payments {
            if let money = rates.convert(payment.money, to: target, on: payment.paidAt) {
                var copy = payment; copy.money = money; converted.append(copy)
            } else { unconverted.append(payment) }
        }
        return (converted, unconverted)
    }
}
