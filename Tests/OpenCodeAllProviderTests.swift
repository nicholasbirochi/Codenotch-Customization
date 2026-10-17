import XCTest
import SQLite3
import SwiftUI
@testable import Codenotch

final class OpenCodeAllProviderTests: XCTestCase {
    private var now: Date {
        NVIDIANIMTokenUsage.calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12))!
    }

    func testAllProvidersAndCacheAreCountedWithoutDoublingAnExplicitTotal() throws {
        for version in [1, 2] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-all-\(UUID()).db")
            defer { try? FileManager.default.removeItem(at: url) }
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            let table = version == 1 ? "message" : "session_message"
            XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE \(table) (type TEXT, time_created INTEGER, data TEXT)", nil, nil, nil), SQLITE_OK)
            let old = NVIDIANIMTokenUsage.calendar.date(byAdding: .month, value: -1, to: now)!
            let rows: [(Date, String, String)] = [
                (now, "assistant", #"{"providerID":"nvidia","tokens":{"input":100,"output":20,"reasoning":5,"cache":{"read":40,"write":7}}}"#),
                (now, "assistant", #"{"model":{"providerID":"google"},"tokens":{"total":300,"input":299,"output":300}}"#),
                (old, "assistant", #"{"providerID":"other","tokens":{"total":60}}"#),
                (now.addingTimeInterval(86400), "assistant", #"{"tokens":{"total":900}}"#),
                (now, "user", #"{"tokens":{"total":999}}"#),
                (now, "assistant", #"{"tokens":{"input":0,"output":0}}"#)
            ]
            for (at, role, data) in rows {
                let payload = String(data.dropLast()) + ",\"role\":\"\(role)\"}"
                let sql = "INSERT INTO \(table) VALUES ('\(role)', \(Int(at.timeIntervalSince1970 * 1000)), '\(payload)')"
                XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            }
            sqlite3_close(db)

            let all = try XCTUnwrap(OpenCodeNVIDIAUsage.read(database: url, now: now, providerID: nil))
            XCTAssertEqual(all.tokensTotal, 532)
            XCTAssertEqual(all.tokensThisYear, 532)
            XCTAssertEqual(all.callsTotal, 3)
            XCTAssertEqual(all.tokensThisMonth, 472)
            XCTAssertEqual(all.tokensToday, 472)
            XCTAssertEqual(all.callsThisMonth, 2)
            XCTAssertEqual(all.last30Days(now: now).count, 30)
            XCTAssertEqual(all.last30Days(now: now).last?.tokens, 472)
            XCTAssertEqual(all.last30Days(now: now).dropLast().filter { $0.tokens == 0 }.count, 29)
            XCTAssertEqual(OpenCodeNVIDIAUsage.read(database: url, now: now)?.tokensTotal, 172)
        }
    }

    func testAllHeadlineAlwaysUsesTheTotalAndKeepsCallsAndDailyHistory() {
        let usage = NVIDIANIMTokenUsage(tokensThisMonth: 120, tokensToday: 20, callsThisMonth: 3,
                                        tokensTotal: 500, dailyTokens: ["2026-10-13": 20])
        let snapshot = OpenCodeAllProvider.snapshot(usage: usage, now: now)
        XCTAssertEqual(snapshot.headline?.used, 500)
        XCTAssertEqual(snapshot.headlineText, "500")
        XCTAssertNil(snapshot.usedFraction)
        XCTAssertEqual(snapshot.windows.first { $0.id == "calls" }?.used, 3)
        XCTAssertEqual(snapshot.dailyTokenUsage?.count, 30)
        XCTAssertEqual(snapshot.dailyTokenUsage?.last?.tokens, 20)
        XCTAssertNotNil(NVIDIANIMProvider.snapshot(usage: usage, rateLimitWindows: [], now: now).dailyTokenUsage)
    }

    @MainActor
    func testNewAllIndicatorConnectsAboveNvidiaOnceAndRespectsLaterDisconnection() throws {
        let name = "opencode-preferences-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["claude", "nvidia-nim", "codex"], forKey: "connectedProviders")
        defaults.set(["claude", "nvidia-nim", "codex"], forKey: "seenProviders")
        defaults.set(["claude", "nvidia-nim", "codex"], forKey: "providerOrder")
        let preferences = Preferences(defaults: defaults)
        let discovered = ["claude", "opencode-all", "nvidia-nim", "codex"]
        preferences.reconcile(discoveredIDs: discovered)
        XCTAssertTrue(preferences.isConnected("opencode-all"))
        XCTAssertEqual(preferences.providerOrder, ["claude", "opencode-all", "nvidia-nim", "codex"])
        preferences.setConnected(false, for: "opencode-all")
        preferences.reconcile(discoveredIDs: discovered)
        XCTAssertFalse(preferences.isConnected("opencode-all"))
    }

    @MainActor
    func testDailyBarsFitBothCardsAndRenderWithDemonstrationData() throws {
        let usage = NVIDIANIMTokenUsage(tokensThisMonth: 38_000, tokensToday: 12_000, callsThisMonth: 15,
            tokensTotal: 250_000, tokensThisYear: 200_000, callsTotal: 90,
            dailyTokens: ["2026-10-08": 4000, "2026-10-09": 7000,
                "2026-10-10": 2000, "2026-10-11": 8000, "2026-10-12": 5000, "2026-10-13": 12000])
        let snapshots = [OpenCodeAllProvider.snapshot(usage: usage, now: now),
            NVIDIANIMProvider.snapshot(usage: usage, rateLimitWindows: [], now: now)]
        for snapshot in snapshots {
            let rows = snapshot.windows.count
            let base = NotchLayout.cardHeight(windowCount: rows, compactRowCount: rows)
            let chart = NotchLayout.cardHeight(windowCount: rows, hasDailyTokenUsage: true, compactRowCount: rows)
            XCTAssertEqual(chart - base, NotchLayout.dailyTokenUsageHeight, accuracy: 0.001)
            let view = TooltipCard(snapshot: snapshot, now: now)
                .padding(20).background(Color.black)
                .environment(\.colorScheme, .dark)
                .environment(\.notchSurfaceStyle, .solid)
                .environment(\.codenotchAccentColor, .cyan)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.nsImage)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            let key = snapshot.id == "nvidia-nim" ? "NVIDIA_RENDER_PATH" : "OPENCODE_RENDER_PATH"
            if let path = ProcessInfo.processInfo.environment[key] {
                try png.write(to: URL(fileURLWithPath: path))
            }
            XCTAssertGreaterThan(png.count, 5000)
        }
    }
}
