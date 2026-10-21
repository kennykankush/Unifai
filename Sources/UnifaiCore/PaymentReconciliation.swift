import Foundation

/// Receipt imports are one-to-one. Ambiguous matches leave the whole import unchanged.
public enum PaymentReconciliation {
    public static func match(_ receipt: PaymentRecord, in payments: [PaymentRecord]) throws -> PaymentRecord? {
        guard receipt.accountID != nil else { return nil }
        let days: Double
        switch receipt.kind {
        case .topUp: days = 7
        case .subscription: days = 5
        case .usageCharge: days = 20
        case .refund: return nil
        }
        let candidates = payments.filter {
            $0.autoRecorded && $0.kind == receipt.kind && $0.accountID == receipt.accountID
                && $0.money.currency == receipt.money.currency
                && abs($0.paidAt.timeIntervalSince(receipt.paidAt)) <= days * 86400
        }
        let sameDay = candidates.filter { Calendar.current.isDate($0.paidAt, inSameDayAs: receipt.paidAt) }
        let exactDay = sameDay.filter { $0.money == receipt.money }
        if exactDay.count == 1 { return exactDay[0] }
        if exactDay.count > 1 { throw ambiguous(receipt) }
        let exact = candidates.filter { $0.money == receipt.money }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw ambiguous(receipt) }
        // A balance-derived estimate can be lower than the receipt because of intervening usage.
        // Only a single candidate on the receipt's day is safe to resolve without an exact amount.
        if sameDay.count == 1 { return sameDay[0] }
        if receipt.kind != .topUp, candidates.count == 1 { return candidates[0] }
        if candidates.count > 0 { throw ambiguous(receipt) }
        return nil
    }

    private static func ambiguous(_ receipt: PaymentRecord) -> ValidationError {
        .message("Could not uniquely match the receipt for \(receipt.description). In Payments, edit the matching estimate with the receipt's amount, date and reference, then import again. Nothing was imported.")
    }
}
