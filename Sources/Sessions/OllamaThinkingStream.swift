import Foundation
import CoreFoundation

/// Observes public stream fields without keeping prompts or completed output.
struct OllamaThinkingStream {
    private var pending = Data()
    private(set) var model: String
    private(set) var isThinking = false
    private var observing: Bool
    private let sse: Bool
    private let native: Bool
    private let streaming: Bool
    private var performance: LocalModelPerformance?
    private var prediction: LocalPrediction?
    private let clock: () -> Date
    private let started: Date
    private var firstToken: Date?
    private let limit = 1_048_576

    init(path: String, body: Data, clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        self.started = clock()
        let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        model = request?["model"] as? String ?? ""
        sse = path == "/v1/chat/completions"
        native = ["/api/chat", "/api/generate"].contains(path)
        streaming = sse ? request?["stream"] as? Bool == true : request?["stream"] as? Bool != false
        observing = !model.isEmpty && (native || (sse && streaming))
    }

    static func modelKey(_ name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.split(separator: "/").last?.contains(":") == true ? name : name + ":latest"
    }

    /// Returns transitions, including both phases if one TCP packet spans them.
    mutating func append(_ data: Data) -> [(String, Bool)] {
        guard observing else { return [] }
        if !streaming {
            guard pending.count + data.count <= limit else {
                observing = false; pending.removeAll(); return []
            }
            pending.append(data)
            return []
        }
        var changes: [(String, Bool)] = []
        for byte in data {
            if byte == 10 {
                let oldModel = model
                let oldState = isThinking
                consume(pending)
                pending.removeAll(keepingCapacity: true)
                if oldModel != model && oldState { changes.append((oldModel, false)) }
                if oldState != isThinking || (oldModel != model && isThinking) {
                    changes.append((model, isThinking))
                }
            } else if pending.count < limit {
                pending.append(byte)
            } else {
                observing = false
                pending.removeAll()
                if isThinking { changes.append((model, false)) }
                isThinking = false
                break
            }
        }
        return changes
    }

    mutating func finish() {
        if observing, !pending.isEmpty { consume(pending) }
        pending.removeAll()
        isThinking = false
        observing = false
    }

    mutating func takePerformance() -> LocalModelPerformance? {
        defer { performance = nil }
        return performance
    }

    mutating func takePrediction() -> LocalPrediction? {
        defer { prediction = nil }
        return prediction
    }

    private mutating func recordPrediction(_ item: [String: Any]) {
        guard item["error"] == nil else { return }
        func count(_ name: String, limit: Double = 1e12) -> Int? {
            guard let value = item[name] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  value.doubleValue >= 0, value.doubleValue < limit,
                  value.doubleValue.rounded(.down) == value.doubleValue else { return nil }
            return value.intValue
        }
        let input = count("prompt_eval_count"), output = count("eval_count")
        guard input != nil || output != nil else { return }
        let seconds = count("eval_duration", limit: 1e18).map { Double($0) / 1e9 }
        let ttft = firstToken.flatMap { token -> TimeInterval? in
            let elapsed = token.timeIntervalSince(started)
            return elapsed >= 0 && elapsed.isFinite ? elapsed : nil
        }
        prediction = LocalPrediction(instance: Self.modelKey(model), at: clock(), inputTokens: input,
            outputTokens: output, tokensPerSecond: performance?.tokensPerSecond,
            timeToFirstToken: ttft, generationSeconds: seconds)
    }

    private mutating func consume(_ line: Data) {
        var data = line
        if sse {
            guard let text = String(data: line, encoding: .utf8), text.hasPrefix("data:") else { return }
            let payload = text.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" { isThinking = false; observing = false; return }
            data = Data(payload.utf8)
        }
        guard !data.isEmpty else { return }
        guard let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            isThinking = false
            observing = false
            return
        }
        if let name = item["model"] as? String, !name.isEmpty { model = name }
        if item["done"] as? Bool == true || item["error"] != nil {
            if native {
                performance = LocalModelPerformance.parse(item)
                recordPrediction(item)
            }
            isThinking = false
            observing = false
            return
        }
        guard streaming else { return }
        let message = item["message"] as? [String: Any] ?? [:]
        var thinking = (item["thinking"] as? String ?? "") + (message["thinking"] as? String ?? "")
        var answer = (item["response"] as? String ?? "") + (message["content"] as? String ?? "")
        var toolCall = !(message["tool_calls"] as? [Any] ?? []).isEmpty
        if sse, let choices = item["choices"] as? [[String: Any]] {
            for choice in choices {
                if let reason = choice["finish_reason"], !(reason is NSNull) {
                    isThinking = false; observing = false; return
                }
                let delta = choice["delta"] as? [String: Any] ?? [:]
                thinking += (delta["reasoning"] as? String ?? "") + (delta["reasoning_content"] as? String ?? "")
                answer += delta["content"] as? String ?? ""
                toolCall = toolCall || !(delta["tool_calls"] as? [Any] ?? []).isEmpty
            }
        }
        if firstToken == nil, !thinking.isEmpty || !answer.isEmpty || toolCall { firstToken = clock() }
        if !answer.isEmpty || toolCall { isThinking = false }
        else if !thinking.isEmpty { isThinking = true }
    }
}
