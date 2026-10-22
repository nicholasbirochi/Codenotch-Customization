import Foundation
import SQLite3

struct NVIDIANIMTokenUsage: Equatable {
    var tokensThisMonth = 0
    var tokensToday = 0
    var callsThisMonth = 0
    var modelTokensThisMonth: [String: Int] = [:]
    var tokensTotal = 0
    var tokensThisYear = 0
    var callsTotal = 0
    var dailyTokens: [String: Int] = [:]
    var historyRecords: [ObservedUsageHistory.Record] = []

    func last30Days(now: Date) -> [CodexTokenUsage.DailyBucket] {
        CodexTokenUsage(dailyUsageBuckets: dailyTokens.map {
            .init(startDate: $0.key, tokens: $0.value)
        }).last30Days(now: now, calendar: Self.calendar)
    }

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
            guard entry.at <= now else { continue }
            usage.tokensTotal += entry.tokens
            usage.callsTotal += entry.calls
            if calendar.isDate(entry.at, equalTo: now, toGranularity: .year) {
                usage.tokensThisYear += entry.tokens
            }
            let date = calendar.dateComponents([.year, .month, .day], from: entry.at)
            let day = String(format: "%04d-%02d-%02d", date.year!, date.month!, date.day!)
            usage.dailyTokens[day, default: 0] += entry.tokens
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
        now: Date = Date(),
        providerID: String? = "nvidia"
    ) -> NVIDIANIMTokenUsage? {
        guard let db = SQLiteStore.open(database) else { return nil }
        defer { sqlite3_close(db) }

        guard let schema = OpenCodeSchema.of(db) else { return nil }
        let rows = SQLiteStore.rows(
            in: db,
            sql: schema.historySQL(in: db, providerID: providerID),
            columns: 9
        ).filter { row in
            guard let stamp = Double(row[0]), stamp.isFinite, stamp >= 0,
                  stamp <= now.timeIntervalSince1970 * 1000 else { return false }
            return (1...6).allSatisfy { column in
                row[column].isEmpty || Int(row[column]).map { $0 >= 0 && $0 < 1_000_000_000_000 } == true
            }
        }

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
        var usage = NVIDIANIMTokenUsage.bucket(entries, now: now)
        usage.historyRecords = zip(entries, rows).compactMap { entry, row in
            guard entry.tokens > 0, entry.at <= now else { return nil }
            let project = row[8].isEmpty ? nil : URL(fileURLWithPath: row[8]).lastPathComponent
            return ObservedUsageHistory.Record(at: entry.at, tokens: entry.tokens,
                input: Int(row[2]), output: Int(row[3]), project: project)
        }
        return usage
    }
}
