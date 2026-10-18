import XCTest
@testable import Codenotch

final class OllamaObservedHistoryTests: XCTestCase {
    func testNativeCompletionRecordsCountsOnceWithoutPersistingText() throws {
        var now = Date(timeIntervalSince1970: 1_792_246_400)
        var stream = OllamaThinkingStream(path: "/api/chat", body: Data(#"{"model":"qwen:7b"}"#.utf8), clock: { now })
        now += 0.5
        _ = stream.append(Data((#"{"message":{"thinking":"never persisted"}}"# + "\n").utf8))
        now += 2
        _ = stream.append(Data((#"{"model":"qwen:7b","done":true,"prompt_eval_count":20,"eval_count":100,"eval_duration":2000000000}"# + "\n").utf8))
        let prediction = try XCTUnwrap(stream.takePrediction())
        XCTAssertEqual(prediction.inputTokens, 20)
        XCTAssertEqual(prediction.outputTokens, 100)
        XCTAssertNil(prediction.reasoningTokens, "Native totals do not provide a reasoning split")
        XCTAssertEqual(prediction.timeToFirstToken, 0.5)
        XCTAssertEqual(prediction.generationSeconds, 2)
        XCTAssertEqual(prediction.tokensPerSecond, 50)
        XCTAssertNil(stream.takePrediction())
        var ledger = LocalTokenLedger()
        ledger.record(prediction, as: "ollama-local:model:qwen:7b")
        let encoded = try JSONEncoder().encode(ledger)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("never persisted"))
        let restored = try JSONDecoder().decode(LocalTokenLedger.self, from: encoded)
        XCTAssertEqual(restored, ledger)
        let history = try XCTUnwrap(restored.history(for: "ollama-local:model:qwen:7b", now: now))
        XCTAssertEqual(history.today.total, 120, "Thinking is already included in output")
        XCTAssertEqual(history.today.requests, 1)
        XCTAssertNil(history.today.projects.first?.name)
    }

    func testLatencyUsesMillisecondsRatherThanChatDurationMinutes() {
        XCTAssertEqual(UsageFormat.responseDuration(seconds: 0.05), "50 ms")
        XCTAssertEqual(UsageFormat.responseDuration(seconds: 0), "0 ms")
        XCTAssertTrue(UsageFormat.responseDuration(seconds: 2.5).hasSuffix(" s"))
        XCTAssertEqual(UsageFormat.responseDuration(seconds: .nan), "—")
        XCTAssertEqual(UsageFormat.responseDuration(seconds: -1), "—")
    }

    func testAbortedAndErroredResponsesDoNotBecomeCompletedRequests() {
        var stream = OllamaThinkingStream(path: "/api/generate", body: Data(#"{"model":"qwen"}"#.utf8))
        _ = stream.append(Data((#"{"response":"partial"}"# + "\n").utf8))
        stream.finish()
        XCTAssertNil(stream.takePrediction())
        var error = OllamaThinkingStream(path: "/api/generate", body: Data(#"{"model":"qwen"}"#.utf8))
        _ = error.append(Data((#"{"done":true,"error":"failed","eval_count":1}"# + "\n").utf8))
        XCTAssertNil(error.takePrediction())
    }
}

@MainActor
final class LocalObservedViewTests: XCTestCase {
    func testCompleteModelMetricsAndHistoryStillFitAllEdges() throws {
        let now = Date()
        let names = (1...5).map { "qwen-\($0):7b" }
        let models = names.map { LocalRuntimeReading.Model(name: $0, memoryBytes: 1024,
            contextLength: 8192, quantizationLevel: "Q4") }
        let vm = NotchViewModel()
        vm.now = now
        vm.setLocalMetricsEnabled(true)
        vm.updateSnapshots([Fixtures.snapshots()[0], ProviderSnapshot(id: "ollama-local", displayName: "Ollama",
            glyph: .ollamaLocal, fidelity: .official, status: .ok, windows: [], kind: .localRuntime,
            localRuntime: .init(models: models))])
        var ledger = LocalTokenLedger()
        ledger.record(.init(instance: names[0], at: now.addingTimeInterval(-1), inputTokens: 1000,
            outputTokens: 100, reasoningTokens: 50, tokensPerSecond: 50, timeToFirstToken: 0.5,
            generationSeconds: 2, draftTokens: 20, acceptedDraftTokens: 10), as: "ollama-local:model:\(names[0])")
        vm.updateLedger(ledger, source: NotchViewModel.ollamaSource)
        vm.isExpanded = true
        vm.screenSize = CGSize(width: 1512, height: 982)
        for size in NotchSize.allCases {
            vm.sizeScale = size.scale
            for edge in NotchEdge.allCases {
                vm.edge = edge
                vm.hoveredIndex = 1
                XCTAssertLessThanOrEqual(vm.panelSize.height, 982.1, "\(edge) \(size)")
                if edge.isVertical {
                    let height = vm.maxCardHeight(cellCount: vm.snapshots.count)
                    XCTAssertLessThanOrEqual(height, vm.panelSize.height)
                    for index in [0, vm.snapshots.count - 1] {
                        let centre = vm.tooltipAlong(index: index, length: height)
                        XCTAssertGreaterThanOrEqual(centre - height / 2, -0.1)
                        XCTAssertLessThanOrEqual(centre + height / 2, vm.panelSize.height + 0.1)
                    }
                }
            }
        }
    }

    func testRelayedModelsHaveIndependentPersistedHistoryAndDoNotReplaceLMStudio() throws {
        let name = "ollama-ledger-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let archive = UsageArchive(defaults: defaults)
        let relay = OllamaActivityRelay(archive: archive)
        let now = Date()
        relay.recordPrediction(.init(instance: "qwen:7b", at: now, inputTokens: 10, outputTokens: 100, tokensPerSecond: 50))
        relay.recordPrediction(.init(instance: "qwen:14b", at: now, inputTokens: 20, outputTokens: 200))
        let restored = OllamaActivityRelay(archive: archive)
        XCTAssertEqual(restored.ledger, relay.ledger)
        let vm = NotchViewModel()
        vm.now = now
        vm.setLocalMetricsEnabled(true)
        vm.updateSnapshots([ProviderSnapshot(id: "ollama-local", displayName: "Ollama", glyph: .ollamaLocal,
            fidelity: .official, status: .ok, windows: [], kind: .localRuntime,
            localRuntime: .init(models: []))])
        vm.updateLedger(restored.ledger, source: NotchViewModel.ollamaSource)
        let seven = try XCTUnwrap(vm.snapshots.first { $0.id == "ollama-local:model:qwen:7b" })
        let fourteen = try XCTUnwrap(vm.snapshots.first { $0.id == "ollama-local:model:qwen:14b" })
        XCTAssertEqual(seven.observedHistory?.observedTotal, 110)
        XCTAssertEqual(fourteen.observedHistory?.observedTotal, 220)
        XCTAssertEqual(seven.localModel?.loaded, false, "Recorded unloaded models remain inspectable")
        XCTAssertEqual(seven.localPerformance?.tokensPerSecond, 50)
        vm.updateLedger(LocalTokenLedger(), source: LMStudioMetrics.providerID)
        XCTAssertEqual(vm.snapshots.first { $0.id == seven.id }?.observedHistory?.observedTotal, 110)
    }

    func testInstalledModelsTheRelayHasNotServedStartFromAnEmptyChart() throws {
        let vm = NotchViewModel()
        vm.now = Date()
        let runtime = ProviderSnapshot(id: "ollama-local", displayName: "Ollama", glyph: .ollamaLocal,
            fidelity: .official, status: .ok, windows: [], kind: .localRuntime,
            localRuntime: .init(models: [.init(name: "qwen3-coder:30b", memoryBytes: 1, contextLength: nil, quantizationLevel: nil,
                                               memoryKind: .modelSize, loaded: false)]))
        vm.setLocalMetricsEnabled(true)
        vm.updateSnapshots([runtime])
        let cell = try XCTUnwrap(vm.snapshots.first { $0.id == "ollama-local:model:qwen3-coder:30b" })
        let history = try XCTUnwrap(cell.observedHistory)
        XCTAssertFalse(history.unavailable)
        XCTAssertEqual(history.source, .relay)
        XCTAssertEqual(history.observedTotal, 0)
        vm.setLocalMetricsEnabled(false)
        vm.updateSnapshots([runtime])
        XCTAssertNotEqual(vm.snapshots.first { $0.id == cell.id }?.observedHistory?.unavailable, false,
                          "Without the relay there is nothing to chart")
    }

    /// The cell under the ring counts what the relay logged in the chart's
    /// period, prompt and response together, never a dash.
    func testTheCellShowsTheTokensSpentInTheChartsPeriod() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func day(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }
        let now = day(10, 15) // a Thursday
        let vm = NotchViewModel()
        vm.now = now
        vm.updateSnapshots([ProviderSnapshot(id: "ollama-local", displayName: "Ollama", glyph: .ollamaLocal,
            fidelity: .official, status: .ok, windows: [], kind: .localRuntime,
            localRuntime: .init(models: [.init(name: "qwen3:8b", memoryBytes: 1, contextLength: nil,
                                               quantizationLevel: nil, memoryKind: .modelSize, loaded: true)]))])
        let id = "ollama-local:model:qwen3:8b"
        let key = UsageHistoryPeriod.preferenceKey(id)
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        let empty = try XCTUnwrap(vm.snapshots.first { $0.id == id })
        XCTAssertEqual(empty.headlineText, "0", "Nothing logged is 0, not a dash")
        XCTAssertTrue(empty.headlineIsPending(period: .month))
        XCTAssertEqual(empty.periodTokensText(.month), "0 tokens this month")

        var ledger = LocalTokenLedger(calendar: calendar)
        for (at, input, output) in [(day(10, 15, 9), 1_000, 200), (day(10, 12), 5_000, 500),
                                    (day(10, 2), 40_000, 4_000), (day(9, 20), 90_000, 10_000)] {
            ledger.record(.init(instance: "qwen3:8b", at: at, inputTokens: input, outputTokens: output), as: id)
        }
        vm.updateLedger(ledger, source: NotchViewModel.ollamaSource)
        let cell = try XCTUnwrap(vm.snapshots.first { $0.id == id })
        XCTAssertEqual(cell.periodTokens(.today), 1_200)
        XCTAssertEqual(cell.periodTokens(.week), 6_700)
        XCTAssertEqual(cell.periodTokens(.month), 50_700)
        XCTAssertEqual(cell.headlineText(period: .today), LimitWindow.compact(1_200))
        XCTAssertEqual(cell.headlineText, LimitWindow.compact(50_700), "The chart opens on the month")
        XCTAssertFalse(cell.headlineIsPending(period: .month))
        XCTAssertEqual(cell.periodTokens(.month), cell.observedHistory?.slice(.month).total,
                       "The same figure as the chart's total")

        UserDefaults.standard.set(UsageHistoryPeriod.week.rawValue, forKey: key)
        XCTAssertEqual(cell.headlineText, LimitWindow.compact(6_700), "The chart's period picker drives the cell")
        XCTAssertEqual(cell.periodTokensText(cell.observedPeriod), "\(LimitWindow.compact(6_700)) tokens this week")
    }
}
