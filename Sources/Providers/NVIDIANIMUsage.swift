import Foundation
import SQLite3

struct NVIDIANIMTokenUsage: Equatable {
    var tokensThisMonth = 0
    var tokensToday = 0
    var callsThisMonth = 0
    var modelTokensThisMonth: [String: Int] = [:]

    static let zero = NVIDIANIMTokenUsage()

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static func startOfMonth(now: Date, calendar: Calendar = NVIDIANIMTokenUsage.calendar) -> Date {
        calendar.dateInterval(of: .month, for: now)!.start
    }

    static func bucket(
        _ entries: [(at: Date, tokens: Int, calls: Int, model: String?)],
        now: Date,
        calendar: Calendar = NVIDIANIMTokenUsage.calendar
    ) -> NVIDIANIMTokenUsage {
        var usage = NVIDIANIMTokenUsage.zero
        for entry in entries where entry.tokens > 0 {
            guard calendar.isDate(entry.at, equalTo: now, toGranularity: .month) else { continue }
            usage.tokensThisMonth += entry.tokens
            usage.callsThisMonth += entry.calls
            if let model = entry.model, !model.isEmpty {
                usage.modelTokensThisMonth[model, default: 0] += entry.tokens
            }
            if calendar.isDate(entry.at, inSameDayAs: now) { usage.tokensToday += entry.tokens }
        }
        return usage
    }
}

enum OpenCodeNVIDIAUsage {
    static var database: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/opencode/opencode.db")
    }

    static func read(
        database: URL = OpenCodeNVIDIAUsage.database,
        now: Date = Date()
    ) -> NVIDIANIMTokenUsage? {
        guard let db = SQLiteStore.open(database) else { return nil }
        defer { sqlite3_close(db) }

        let startOfMonth = Int(NVIDIANIMTokenUsage.startOfMonth(now: now).timeIntervalSince1970 * 1000)
        guard let schema = OpenCodeSchema.of(db) else { return nil }
        let rows = SQLiteStore.rows(
            in: db,
            sql: schema.usageSQL(startOfMonth: startOfMonth, providerID: "nvidia"),
            columns: 8
        )

        let entries: [(at: Date, tokens: Int, calls: Int, model: String?)] = rows.compactMap { row in
            guard let milliseconds = Double(row[0]) else { return nil }
            let total = Int(row[1]) ?? 0
            let tokens = total > 0 ? total : (2...6).reduce(0) { $0 + (Int(row[$1]) ?? 0) }
            return (
                at: Date(timeIntervalSince1970: milliseconds / 1000),
                tokens: tokens,
                calls: 1,
                model: row[7].isEmpty ? nil : row[7]
            )
        }
        return NVIDIANIMTokenUsage.bucket(entries, now: now)
    }
}
