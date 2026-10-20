import XCTest
import SwiftUI
import SQLite3
@testable import Codenotch

final class ObservedUsageHistoryTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return value
    }
    func date(_ day: Int, hour: Int = 12, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    func testCalendarPeriodsAndProjectSharesUseOnlyRealMetadata() {
        let now = date(17, hour: 20)
        let history = ObservedUsageHistory.aggregate([
            .init(at: date(17, hour: 9), tokens: 100, input: 80, output: 20, project: "A"),
            .init(at: date(17, hour: 10), tokens: 50, input: 30, output: 20, project: "B"),
            .init(at: date(17, hour: 11), tokens: 30),
            .init(at: date(17, hour: 12), tokens: 10, project: "C"),
            .init(at: date(17, hour: 13), tokens: 10, project: "D"),
            .init(at: date(1), tokens: 200, project: "Earlier"),
            .init(at: date(1, month: 9), tokens: 300),
            .init(at: date(18), tokens: 999)
        ], now: now, calendar: calendar)
        XCTAssertEqual(history.observedTotal, 700)
        XCTAssertEqual(history.today.total, 200)
        XCTAssertEqual(history.today.buckets.count, 24)
        XCTAssertEqual(history.week.total, 200)
        XCTAssertEqual(history.week.buckets.count, 7)
        XCTAssertEqual(history.month.total, 400)
        XCTAssertEqual(history.month.buckets.count, 31)
        XCTAssertEqual(history.today.requests, 5)
        XCTAssertNil(history.today.input, "Partial input counts are not complete totals")
        XCTAssertEqual(history.today.projects.map(\.tokens), [100, 50, 30, 20])
        XCTAssertNil(history.today.projects[2].name, "Unknown is never inferred from prompts")
        XCTAssertTrue(history.today.projects[3].isOther)
        XCTAssertEqual(history.today.projects.reduce(0) { $0 + $1.tokens }, history.today.total)
        XCTAssertEqual(history.today.peak, 100)
    }

    func testDaylightSavingAndCoarseDataDoNotInventHourlyUsage() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 20))!
        let history = ObservedUsageHistory.aggregate([.init(at: now, tokens: 42)], now: now, calendar: cal)
        XCTAssertEqual(history.today.buckets.count, 23)
        let coarse = ObservedUsageHistory.aggregate([.init(at: now, tokens: 42, requests: nil)],
            now: now, calendar: cal, hourly: false)
        XCTAssertFalse(coarse.today.hourly)
        XCTAssertEqual(coarse.today.buckets.count, 1)
        XCTAssertNil(coarse.today.requests)
        XCTAssertEqual(coarse.today.total, 42)
    }

    func testNewHistoryCannotMakeUnavailableMetricsLookLikeZero() {
        let now = date(17)
        let history = ObservedUsageHistory.aggregate([.init(at: now, tokens: -3),
            .init(at: now.addingTimeInterval(1), tokens: 9)], now: now, calendar: calendar)
        XCTAssertEqual(history.observedTotal, 0)
        XCTAssertNil(history.observedRequests)
        XCTAssertTrue(ObservedUsageHistory.unsupported.unavailable)
        XCTAssertNotEqual(UsageHistoryPeriod.preferenceKey("nvidia-nim"), UsageHistoryPeriod.preferenceKey("ollama-local:model:qwen"))
        let recorded = ObservedUsageHistory.aggregate([.init(at: now, tokens: 1)], now: now, calendar: calendar)
        XCTAssertFalse(recorded.isCurrent(.today, now: date(18), calendar: calendar))
        XCTAssertTrue(recorded.isCurrent(.month, now: date(18), calendar: calendar))
    }

    func testSQLiteProjectJoinReadsDirectoryOnlyAndKeepsProviderFilter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID()).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let timestamp = Int(date(17).timeIntervalSince1970 * 1000)
        let sql = """
        CREATE TABLE session (id TEXT, data TEXT);
        CREATE TABLE message (session_id TEXT, time_created INTEGER, data TEXT);
        INSERT INTO session VALUES ('s', '{"directory":"/demo/RealProject","title":"ignored"}');
        INSERT INTO message VALUES ('s', \(timestamp), '{"role":"assistant","providerID":"nvidia","tokens":{"input":10,"output":20},"text":"must not enter history"}');
        INSERT INTO message VALUES ('s', \(timestamp), '{"role":"assistant","providerID":"other","tokens":{"total":999}}');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let usage = try XCTUnwrap(OpenCodeNVIDIAUsage.read(database: url, now: date(17, hour: 20)))
        XCTAssertEqual(usage.tokensTotal, 30)
        XCTAssertEqual(usage.historyRecords.count, 1)
        XCTAssertEqual(usage.historyRecords.first?.project, "RealProject")
        XCTAssertEqual(usage.historyRecords.first?.input, 10)
        XCTAssertEqual(usage.historyRecords.first?.output, 20)
    }

    func testYearIsTheCalendarYearInMonthlyBars() {
        let now = date(17, hour: 20)
        let history = ObservedUsageHistory.aggregate([
            .init(at: date(17, hour: 9), tokens: 100),
            .init(at: date(3, month: 2), tokens: 40),
            .init(at: calendar.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 12))!, tokens: 900)
        ], now: now, calendar: calendar)
        XCTAssertEqual(history.year.buckets.count, 12)
        XCTAssertFalse(history.year.hourly)
        XCTAssertEqual(history.year.total, 140, "last December is another year")
        XCTAssertEqual(history.year.buckets[1].tokens, 40)
        XCTAssertEqual(history.year.buckets[9].tokens, 100)
        XCTAssertTrue(history.isCurrent(.year, now: now, calendar: calendar))
        XCTAssertEqual(UsageHistoryPeriod.year.stamp(history.year.buckets[0].at, hourly: false),
                       history.year.buckets[0].at.formatted(.dateTime.month()))
    }

    func testPeriodLabelsStayEnglishOnEveryCard() {
        XCTAssertEqual(UsageHistoryPeriod.allCases.map(\.title), ["Today", "Week", "Month", "Year"])
        XCTAssertEqual(TokenChartPeriod.allCases.map(\.title), ["Week", "Month", "Year"])
        XCTAssertEqual(CostSection.tabs.map(\.shortTitle), ["Today", "Week", "Month", "Year"])
    }

    func testCostYearStartsOnTheFirstOfJanuary() throws {
        let start = try XCTUnwrap(CostRange.year.start)
        let parts = Calendar.current.dateComponents([.month, .day, .hour], from: start)
        XCTAssertEqual([parts.month, parts.day, parts.hour], [1, 1, 0])
    }
}

@MainActor
final class ObservedUsageRenderTests: XCTestCase {
    func testEmptyTodayDoesNotRemoveTheProjectSelector() {
        XCTAssertEqual(CostSection.rowCount(state: .ready, projects: 3), 3)
        XCTAssertEqual(CostSection.rowCount(state: .waiting, projects: 0), 1)
        XCTAssertEqual(CostSection.rowCount(state: .ready, projects: 0), 1)
        XCTAssertEqual(CostSection.rowCount(state: .unavailable, projects: 0), 0)
    }

    func testEveryPeriodAndEmptyHistoryKeepsTheSameGeometry() throws {
        let name = "history-ui-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_792_246_400)
        let history = ObservedUsageHistory.aggregate([
            .init(at: now.addingTimeInterval(-3600), tokens: 12000, input: 8000, output: 4000, project: "Demo"),
            .init(at: now.addingTimeInterval(-86400), tokens: 6000, input: 4000, output: 2000)
        ], now: now)
        var unavailable = ObservedUsageHistory.unsupported
        unavailable.source = history.source
        var heights: [String: CGFloat] = [:]
        for period in UsageHistoryPeriod.allCases {
            defaults.set(period.rawValue, forKey: UsageHistoryPeriod.preferenceKey("demo"))
            for (label, value) in [("recorded", history), ("unavailable", unavailable)] {
                let view = ObservedUsageSection(history: value, providerID: "demo", defaults: defaults, now: now)
                    .frame(width: NotchLayout.cardWidth - 2 * NotchLayout.cardPadding)
                    .padding(20).foregroundStyle(.white).background(.black)
                    .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.nsImage)
                if let height = heights[label] { XCTAssertEqual(image.size.height, height, accuracy: 0.01) }
                heights[label] = image.size.height
                if let directory = ProcessInfo.processInfo.environment["HISTORY_RENDER_DIR"], label == "recorded" {
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("history-\(period.rawValue).png"))
                }
            }
        }
        XCTAssertEqual(CostSection.tabs, [.today, .weekly, .month, .year])
        XCTAssertEqual(UsageHistoryPeriod.allCases, [.today, .week, .month, .year])
        if let directory = ProcessInfo.processInfo.environment["HISTORY_RENDER_DIR"] {
            for (id, glyph, title, value) in [
                ("demo-nvidia", ProviderGlyph.nvidia, "NVIDIA NIM", history),
                ("demo-copilot", ProviderGlyph.copilot, "GitHub Copilot", unavailable)
            ] {
                var snapshot = ProviderSnapshot(id: id, displayName: title, glyph: glyph,
                    fidelity: .derived, status: .ok, windows: [])
                snapshot.observedHistory = value
                let renderer = ImageRenderer(content: TooltipCard(snapshot: snapshot, now: now)
                    .environment(\.colorScheme, .dark))
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.nsImage)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("\(id).png"))
            }
        }
    }
}
