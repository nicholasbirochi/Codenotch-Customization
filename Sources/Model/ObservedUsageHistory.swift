import Foundation

/// A choice in `UsagePeriodPicker`.
protocol PeriodOption: CaseIterable, Identifiable, Equatable where AllCases: RandomAccessCollection {
    var title: String { get }
}

enum UsageHistoryPeriod: String, CaseIterable, Identifiable, Codable, PeriodOption {
    case today, week, month, year
    var id: String { rawValue }
    /// English in every language, as asked: the picker reads Today, Week,
    /// Month, Year on every card.
    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        }
    }
    var component: Calendar.Component {
        switch self {
        case .today: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
    func interval(now: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: component, for: now)!
    }
    static func preferenceKey(_ providerID: String) -> String { "usageHistory.period.\(providerID)" }

    /// The first and last bar's date under a chart: the hour today, the month
    /// for a year of monthly bars, the day otherwise.
    func stamp(_ date: Date?, hourly: Bool) -> String {
        guard let date else { return "—" }
        if hourly { return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted))) }
        return date.formatted(self == .year ? .dateTime.month() : .dateTime.day().month())
    }
}

/// Count/date/project metadata only; no message content or inferred attribution.
struct ObservedUsageHistory: Equatable, Codable {
    struct Record: Equatable {
        var at: Date
        var tokens: Int
        var requests: Int? = 1
        var input: Int? = nil
        var output: Int? = nil
        var project: String? = nil
    }
    struct Bucket: Equatable, Codable, Identifiable {
        var at: Date
        var tokens: Int
        var id: Date { at }
    }
    struct Project: Equatable, Codable, Identifiable {
        var name: String?
        var tokens: Int
        var isOther = false
        var id: String { isOther ? "other" : name.map { "named:\($0)" } ?? "unknown" }
        var title: String { isOther ? L10n.t("Other") : name ?? L10n.t("Unidentified project") }
    }
    struct Slice: Equatable, Codable {
        var buckets: [Bucket] = []
        var total = 0
        var requests: Int? = nil
        var input: Int? = nil
        var output: Int? = nil
        var projects: [Project] = []
        var hourly = false
        var peak: Int { buckets.map(\.tokens).max() ?? 0 }
    }
    var today = Slice()
    var week = Slice()
    var month = Slice()
    /// Optional so readings archived before the Year period still decode.
    private var yearSlice: Slice? = nil
    var year: Slice {
        get { yearSlice ?? Slice() }
        set { yearSlice = newValue }
    }
    var observedTotal = 0
    var observedRequests: Int? = nil
    var firstObserved: Date? = nil
    var asOf: Date? = nil
    var model: String? = nil
    var unavailable = false
    enum Source: String, Codable { case openCode, relay, runtimeLog, quota }
    var source: Source = .openCode

    var sourceTitle: String {
        switch source {
        case .openCode: return L10n.t("OpenCode local history")
        case .relay: return L10n.t("Optional local response capture")
        case .runtimeLog: return L10n.t("Local runtime logs")
        case .quota: return L10n.t("Official provider quotas")
        }
    }
    func note(period: UsageHistoryPeriod) -> String {
        if unavailable { return L10n.t("This source does not provide dated usage or project attribution.") }
        if period == .today && !today.hourly { return L10n.t("Only daily totals are available; hourly distribution is unknown.") }
        switch source {
        case .openCode: return L10n.t("Observed OpenCode tokens, including cache. Not an official quota.")
        case .relay: return L10n.t("Only responses through the optional local relay. Retained for 60 days.")
        case .runtimeLog: return L10n.t("Runtime counts retained for 60 days. Unknown projects are not inferred.")
        case .quota: return L10n.t("Event history unavailable")
        }
    }

    /// Keep the same project capacity across periods; unknown-only runtimes need one row.
    var projectRowCount: Int {
        min(4, max(source == .openCode ? 4 : 1, today.projects.count, week.projects.count, month.projects.count,
                             year.projects.count))
    }

    static var unsupported: Self { Self(unavailable: true, source: .quota) }

    func isCurrent(_ period: UsageHistoryPeriod, now: Date, calendar: Calendar = .current) -> Bool {
        guard let asOf else { return false }
        return period.interval(now: now, calendar: calendar).contains(asOf)
    }

    func slice(_ period: UsageHistoryPeriod) -> Slice {
        switch period {
        case .today: return today
        case .week: return week
        case .month: return month
        case .year: return year
        }
    }

    static func aggregate(_ records: [Record], now: Date, calendar: Calendar = .current,
                          hourly: Bool = true) -> Self {
        let valid = records.filter {
            $0.at.timeIntervalSince1970.isFinite && $0.at.timeIntervalSince1970 >= 0 && $0.at <= now && $0.tokens >= 0
                && ($0.requests.map { $0 >= 0 } ?? true)
                && ($0.input.map { $0 >= 0 } ?? true) && ($0.output.map { $0 >= 0 } ?? true)
        }
        var result = Self()
        result.asOf = now
        result.observedTotal = valid.reduce(0) { $0 + $1.tokens }
        result.observedRequests = sumKnown(valid.map(\.requests))
        result.firstObserved = valid.map(\.at).min()
        for period in UsageHistoryPeriod.allCases {
            let interval = period.interval(now: now, calendar: calendar)
            let selected = valid.filter { interval.contains($0.at) && $0.at < interval.end }
            // A year in days is 365 hair-thin bars; months read better.
            let component: Calendar.Component = period == .today && hourly ? .hour
                : period == .year ? .month : .day
            var bucketValues: [Date: Int] = [:]
            var projects: [String: Int] = [:]
            for record in selected {
                let start = calendar.dateInterval(of: component, for: record.at)!.start
                bucketValues[start, default: 0] += record.tokens
                projects[record.project ?? "", default: 0] += record.tokens
            }
            var slice = Slice()
            var cursor = interval.start
            // Calendar stepping also handles 23/25-hour days and month lengths.
            while cursor < interval.end {
                slice.buckets.append(Bucket(at: cursor, tokens: bucketValues[cursor] ?? 0))
                guard let next = calendar.date(byAdding: component, value: 1, to: cursor), next > cursor else { break }
                cursor = next
            }
            slice.hourly = component == .hour
            slice.total = selected.reduce(0) { $0 + $1.tokens }
            slice.requests = sumKnown(selected.map(\.requests))
            slice.input = sumKnown(selected.map(\.input))
            slice.output = sumKnown(selected.map(\.output))
            let sorted = projects.filter { $0.value > 0 }.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }
            slice.projects = sorted.prefix(3).map { Project(name: $0.key.isEmpty ? nil : $0.key, tokens: $0.value) }
            let others = sorted.dropFirst(3).reduce(0) { $0 + $1.value }
            if others > 0 { slice.projects.append(Project(name: nil, tokens: others, isOther: true)) }
            switch period {
            case .today: result.today = slice
            case .week: result.week = slice
            case .month: result.month = slice
            case .year: result.year = slice
            }
        }
        return result
    }

    private static func sumKnown(_ values: [Int?]) -> Int? {
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
        return values.reduce(0) { $0 + $1! }
    }
}
