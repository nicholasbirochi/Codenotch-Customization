import SQLite3
import XCTest
@testable import Codenotch

private func nvidiaDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    return NVIDIANIMTokenUsage.calendar.date(from: components)!
}

final class NVIDIANIMTokenUsageTests: XCTestCase {
    private let now = nvidiaDate(2026, 9, 15)

    func testItBucketsMonthTodayCallsAndModels() {
        let usage = NVIDIANIMTokenUsage.bucket([
            (at: now, tokens: 1200, calls: 1, model: "nvidia/nemotron"),
            (at: nvidiaDate(2026, 9, 3), tokens: 300, calls: 1, model: "nvidia/nemotron"),
            (at: nvidiaDate(2026, 8, 28), tokens: 999, calls: 1, model: "nvidia/old"),
            (at: nvidiaDate(2025, 12, 31), tokens: 11, calls: 1, model: "nvidia/previous-year"),
            (at: now.addingTimeInterval(86400), tokens: 900, calls: 1, model: "nvidia/future"),
            (at: now, tokens: 0, calls: 1, model: "nvidia/aborted")
        ], now: now)

        XCTAssertEqual(usage.tokensThisMonth, 1500)
        XCTAssertEqual(usage.tokensToday, 1200)
        XCTAssertEqual(usage.callsThisMonth, 2)
        XCTAssertEqual(usage.tokensTotal, 2510)
        XCTAssertEqual(usage.tokensThisYear, 2499)
        XCTAssertEqual(usage.callsTotal, 4)
        XCTAssertEqual(usage.modelTokensThisMonth, ["nvidia/nemotron": 1500])
    }
}

final class NVIDIANIMCredentialsTests: XCTestCase {
    func testAccountLinksToNvidiaAPIKeys() throws {
        let account = try XCTUnwrap(NVIDIANIMCredentials.account(environment: [
            NVIDIANIMCredentials.environmentKey: "nvapi-test"
        ], keychain: { nil }))

        XCTAssertEqual(account.manageURL?.absoluteString, "https://build.nvidia.com/settings/api-keys")
    }

    func testItReadsTheAPIKeyFromZshrcForFinderLaunches() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvidia-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try #"export NVIDIA_API_KEY="nvapi-from-zshrc""#
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let credential = try XCTUnwrap(NVIDIANIMCredentials.load(environment: [:], home: home, keychain: { nil }))
        XCTAssertEqual(credential.token, "nvapi-from-zshrc")
        XCTAssertEqual(credential.source, "~/.zshrc")
        XCTAssertEqual(NVIDIANIMCredentials.account(environment: [:], home: home, keychain: { nil })?.source, "~/.zshrc")
    }

    func testEnvironmentWinsOverShellFiles() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvidia-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try #"export NVIDIA_API_KEY="nvapi-from-zshrc""#
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let credential = try XCTUnwrap(NVIDIANIMCredentials.load(
            environment: [NVIDIANIMCredentials.environmentKey: "nvapi-from-env"],
            home: home,
            keychain: { nil }
        ))
        XCTAssertEqual(credential.token, "nvapi-from-env")
        XCTAssertEqual(credential.source, NVIDIANIMCredentials.environmentKey)
    }

    func testKeychainWinsOverEnvironmentAndShellFiles() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvidia-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try #"export NVIDIA_API_KEY="nvapi-from-zshrc""#
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let credential = try XCTUnwrap(NVIDIANIMCredentials.load(
            environment: [NVIDIANIMCredentials.environmentKey: "nvapi-from-env"],
            home: home,
            keychain: { " nvapi-from-keychain\n" }
        ))
        XCTAssertEqual(credential.token, "nvapi-from-keychain")
        XCTAssertEqual(credential.source, NVIDIANIMCredentials.keychainSource)
    }

    func testEmptyKeychainItemFallsBackToTheEnvironment() throws {
        let credential = try XCTUnwrap(NVIDIANIMCredentials.load(
            environment: [NVIDIANIMCredentials.environmentKey: "nvapi-from-env"],
            home: FileManager.default.temporaryDirectory,
            keychain: { "   " }
        ))
        XCTAssertEqual(credential.source, NVIDIANIMCredentials.environmentKey)
    }

    func testItReadsTheManualMonthlyBudgetFromZshrc() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvidia-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try #"export NVIDIA_NIM_MONTHLY_TOKEN_BUDGET="1_000_000""#
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        XCTAssertEqual(NVIDIANIMCredentials.monthlyTokenBudget(environment: [:], home: home), 1_000_000)
    }
}

final class OpenCodeNVIDIAUsageTests: XCTestCase {
    private let now = nvidiaDate(2026, 9, 15)
    private var databases: [URL] = []

    override func tearDownWithError() throws {
        for url in databases { try? FileManager.default.removeItem(at: url) }
        databases = []
    }

    private struct Row {
        let created: Date
        let type: String
        let data: String
    }

    private func makeV2Database(_ rows: [Row]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-nvidia-2x-\(UUID().uuidString).db")
        databases.append(url)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
        CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
                                      type TEXT NOT NULL, seq INTEGER NOT NULL,
                                      time_created INTEGER NOT NULL,
                                      time_updated INTEGER NOT NULL, data TEXT NOT NULL);
        """, nil, nil, nil)
        for (index, row) in rows.enumerated() {
            let millis = Int(row.created.timeIntervalSince1970 * 1000)
            let data = row.data.replacingOccurrences(of: "'", with: "''")
            sqlite3_exec(db, """
            INSERT INTO session_message VALUES ('m\(index)', 's1', '\(row.type)', \(index),
                                                \(millis), \(millis), '\(data)');
            """, nil, nil, nil)
        }
        sqlite3_close(db)
        return url
    }

    private func assistant(
        provider: String = "nvidia",
        model: String = "nvidia/nemotron-3-ultra-550b-a55b",
        input: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        read: Int = 0,
        write: Int = 0
    ) -> String {
        #"{"model":{"id":"\#(model)","providerID":"\#(provider)"},"#
            + #""tokens":{"input":\#(input),"output":\#(output),"reasoning":\#(reasoning),"#
            + #""cache":{"read":\#(read),"write":\#(write)}}}"#
    }

    func testV2CountsOnlyNvidiaRowsAndKeepsModelBreakdown() throws {
        let url = try makeV2Database([
            Row(created: now, type: "assistant",
                data: assistant(input: 1000, output: 200, reasoning: 50, read: 5000, write: 100)),
            Row(created: nvidiaDate(2026, 9, 3), type: "assistant",
                data: assistant(model: "nvidia/llama-3.3-nemotron", input: 200, output: 50)),
            Row(created: now, type: "assistant",
                data: assistant(provider: "google", input: 9999)),
            Row(created: now, type: "user",
                data: assistant(input: 9999)),
            Row(created: nvidiaDate(2026, 8, 28), type: "assistant",
                data: assistant(input: 9999))
        ])

        let usage = try XCTUnwrap(OpenCodeNVIDIAUsage.read(database: url, now: now))
        XCTAssertEqual(usage.tokensThisMonth, 6600)
        XCTAssertEqual(usage.tokensToday, 6350)
        XCTAssertEqual(usage.callsThisMonth, 2)
        XCTAssertEqual(usage.tokensTotal, 16599)
        XCTAssertEqual(usage.tokensThisYear, 16599)
        XCTAssertEqual(usage.callsTotal, 3)
        XCTAssertEqual(usage.modelTokensThisMonth["nvidia/nemotron-3-ultra-550b-a55b"], 6350)
        XCTAssertEqual(usage.modelTokensThisMonth["nvidia/llama-3.3-nemotron"], 250)
    }

    func testV1TotalWinsOverComponentSum() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-nvidia-1x-\(UUID().uuidString).db")
        databases.append(url)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
        CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER,
                              time_updated INTEGER, data TEXT);
        """, nil, nil, nil)
        let millis = Int(now.timeIntervalSince1970 * 1000)
        sqlite3_exec(db, """
        INSERT INTO message VALUES ('m1','s1',\(millis),\(millis),
          '{"role":"assistant","providerID":"nvidia","modelID":"nvidia/nemotron",
            "tokens":{"total":96008,"input":1,"output":2,"reasoning":3,
                      "cache":{"read":4,"write":5}}}');
        """, nil, nil, nil)
        sqlite3_close(db)

        let usage = try XCTUnwrap(OpenCodeNVIDIAUsage.read(database: url, now: now))
        XCTAssertEqual(usage.tokensThisMonth, 96008)
        XCTAssertEqual(usage.modelTokensThisMonth, ["nvidia/nemotron": 96008])
    }
}

final class NVIDIANIMProviderSnapshotTests: XCTestCase {
    func testRequestedRowsUseNvidiaHistoryAndAllTimeCalls() {
        let usage = NVIDIANIMTokenUsage(tokensThisMonth: 1200, tokensToday: 300, callsThisMonth: 2,
            tokensTotal: 9000, tokensThisYear: 6000, callsTotal: 12)
        let snapshot = NVIDIANIMProvider.snapshot(usage: usage, rateLimitWindows: [],
            now: nvidiaDate(2026, 9, 15))
        XCTAssertEqual(snapshot.windows.map(\.label), [
            "OpenCode tokens all", "OpenCode tokens this year", "OpenCode tokens this month",
            "OpenCode tokens today", "OpenCode calls"
        ])
        XCTAssertEqual(snapshot.windows.map(\.used), [9000, 6000, 1200, 300, 12])
        XCTAssertEqual(snapshot.headlineID, "opencode-all")
        XCTAssertNil(snapshot.usedFraction)
        XCTAssertEqual(snapshot.dailyTokenUsage?.count, 30)
    }

    func testTheProviderUsesTheNvidiaGlyphAsset() throws {
        XCTAssertEqual(ProviderGlyph.nvidia.rawValue, "nvidia")
        XCTAssertEqual(ProviderGlyph.nvidia.assetName, "glyph-nvidia")
        XCTAssertEqual(ProviderGlyph.nvidia.outline, [])
        XCTAssertNotNil(NSImage(named: ProviderGlyph.nvidia.assetName))
        XCTAssertEqual(NVIDIANIMProvider.snapshot(usage: nil, rateLimitWindows: []).glyph, .nvidia)
    }

    func testOfficialTokenLimitBecomesHeadlineWhenOpenCodeUsageExists() {
        let usage = NVIDIANIMTokenUsage(tokensThisMonth: 1200, tokensToday: 300, callsThisMonth: 2)
        let requests = LimitWindow(id: "requests", label: "NVIDIA API requests",
                                   usedFraction: 0.25, remaining: 75, used: 25)
        let tokens = LimitWindow(id: "tokens", label: "NVIDIA API tokens",
                                 usedFraction: 0.40, remaining: 6000, used: 4000)

        let snapshot = NVIDIANIMProvider.snapshot(
            usage: usage,
            rateLimitWindows: [requests, tokens],
            now: nvidiaDate(2026, 9, 15)
        )

        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(snapshot.headlineID, "tokens")
        XCTAssertEqual(snapshot.headline?.remaining, 6000)
        XCTAssertTrue(snapshot.windows.contains { $0.id == "opencode-month" && $0.used == 1200 })
    }

    func testManualBudgetDrawsTheOpenCodeMonthLineWhenNoOfficialLimitExists() {
        let usage = NVIDIANIMTokenUsage(tokensThisMonth: 250_000, tokensToday: 300, callsThisMonth: 2)

        let snapshot = NVIDIANIMProvider.snapshot(
            usage: usage,
            rateLimitWindows: [],
            monthlyBudget: 1_000_000,
            now: nvidiaDate(2026, 9, 15)
        )

        let month = snapshot.windows.first { $0.id == "opencode-month" }
        XCTAssertEqual(snapshot.fidelity, .manual)
        XCTAssertEqual(snapshot.headlineID, "opencode-month")
        XCTAssertEqual(month?.label, "OpenCode tokens this month")
        XCTAssertEqual(month?.detail, "250k · budget 1.0M")
        XCTAssertEqual(month?.usedFraction, 0.25)
    }

    func testRateLimitHeadersBecomeOfficialWindows() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: NVIDIANIMRateLimits.modelsEndpoint,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "x-ratelimit-limit-requests": "100",
                "x-ratelimit-remaining-requests": "75",
                "x-ratelimit-reset-requests": "60"
            ]
        ))

        let windows = NVIDIANIMRateLimits.windows(from: response, now: nvidiaDate(2026, 9, 15))
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].id, "requests")
        XCTAssertEqual(windows[0].used, 25)
        XCTAssertEqual(windows[0].remaining, 75)
        XCTAssertEqual(windows[0].usedFraction, 0.25)
        XCTAssertEqual(windows[0].detail, "25 used · 75 left")
    }

    func testTokenRateLimitHeadersComeBeforeRequestHeaders() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: NVIDIANIMRateLimits.modelsEndpoint,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "x-ratelimit-limit-tokens": "100000",
                "x-ratelimit-remaining-tokens": "75000",
                "x-ratelimit-reset-tokens": "3600",
                "x-ratelimit-limit-requests": "100",
                "x-ratelimit-remaining-requests": "80",
                "x-ratelimit-reset-requests": "60"
            ]
        ))

        let windows = NVIDIANIMRateLimits.windows(from: response, now: nvidiaDate(2026, 9, 15))
        XCTAssertEqual(windows.map(\.id), ["tokens", "requests"])
        XCTAssertEqual(windows[0].usedFraction, 0.25)
        XCTAssertEqual(windows[0].used, 25000)
        XCTAssertEqual(windows[0].remaining, 75000)
        XCTAssertEqual(windows[0].detail, "25k used · 75k left")
    }
}
