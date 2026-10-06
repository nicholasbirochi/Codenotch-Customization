import Foundation

actor NVIDIANIMProvider: UsageProvider {
    fileprivate static let providerID = "nvidia-nim"
    fileprivate static let providerName = "NVIDIA NIM"

    nonisolated let id = NVIDIANIMProvider.providerID
    nonisolated let displayName = NVIDIANIMProvider.providerName
    nonisolated let glyph = ProviderGlyph.nvidia

    private let session: URLSession
    private let database: URL
    private let credential: @Sendable () -> NVIDIANIMCredentials.Credential?
    private let monthlyBudget: @Sendable () -> Int?

    init(
        session: URLSession = .shared,
        database: URL = OpenCodeNVIDIAUsage.database,
        credential: @escaping @Sendable () -> NVIDIANIMCredentials.Credential? = {
            NVIDIANIMCredentials.load()
        },
        monthlyBudget: @escaping @Sendable () -> Int? = {
            NVIDIANIMCredentials.monthlyTokenBudget()
        }
    ) {
        self.session = session
        self.database = database
        self.credential = credential
        self.monthlyBudget = monthlyBudget
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Set NVIDIA_API_KEY in your environment or shell profile. Optional: set NVIDIA_NIM_MONTHLY_TOKEN_BUDGET to draw a manual OpenCode budget line."))
    }

    nonisolated func account() -> ProviderAccount? { NVIDIANIMCredentials.account() }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let usage = OpenCodeNVIDIAUsage.read(database: database)
        guard let credential = credential() else {
            guard let usage else { throw UsageProviderError.needsAuth }
            return Self.snapshot(usage: usage, rateLimitWindows: [], monthlyBudget: monthlyBudget(), now: Date())
        }

        do {
            let rateLimits = try await rateLimitWindows(token: credential.token)
            if usage == nil, rateLimits.isEmpty {
                throw UsageProviderError.nothingMetered(
                    L10n.t("NVIDIA NIM accepted the key, but did not publish quota headers and OpenCode has no recorded NVIDIA calls yet.")
                )
            }
            return Self.snapshot(
                usage: usage,
                rateLimitWindows: rateLimits,
                monthlyBudget: monthlyBudget(),
                now: Date()
            )
        } catch {
            if let usage {
                return Self.snapshot(usage: usage, rateLimitWindows: [], monthlyBudget: monthlyBudget(), now: Date())
            }
            throw error
        }
    }

    static func snapshot(
        usage: NVIDIANIMTokenUsage?,
        rateLimitWindows: [LimitWindow],
        monthlyBudget: Int? = nil,
        now: Date = Date()
    ) -> ProviderSnapshot {
        let calendar = NVIDIANIMTokenUsage.calendar
        let validatedBudget = monthlyBudget.flatMap { $0 > 0 ? $0 : nil }
        var windows = rateLimitWindows
        if let usage {
            let month = calendar.dateInterval(of: .month, for: now)
            let budget = rateLimitWindows.isEmpty ? validatedBudget : nil
            windows += [
                LimitWindow(
                    id: "opencode-month",
                    label: budget.map { "OpenCode tokens this month · budget \(LimitWindow.compact($0))" }
                        ?? "OpenCode tokens this month",
                    usedFraction: budget.map { Double(usage.tokensThisMonth) / Double($0) },
                    used: usage.tokensThisMonth,
                    resetsAt: month?.end,
                    duration: month?.duration
                ),
                LimitWindow(
                    id: "opencode-today",
                    label: "OpenCode tokens today",
                    used: usage.tokensToday,
                    resetsAt: calendar.dateInterval(of: .day, for: now)?.end
                ),
                LimitWindow(
                    id: "opencode-calls",
                    label: "OpenCode calls this month",
                    used: usage.callsThisMonth
                )
            ]
            windows += usage.modelTokensThisMonth
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(5)
                .enumerated()
                .map { index, model in
                    LimitWindow(
                        id: "opencode-model-\(index)",
                        label: "OpenCode · \(model.key)",
                        used: model.value
                    )
                }
        }

        return ProviderSnapshot(
            id: providerID,
            displayName: providerName,
            glyph: .nvidia,
            fidelity: rateLimitWindows.isEmpty ? (validatedBudget == nil ? .derived : .manual) : .official,
            status: .ok,
            windows: windows,
            headlineID: rateLimitWindows.first { $0.id == "tokens" }?.id
                ?? rateLimitWindows.first?.id
                ?? (usage == nil ? nil : "opencode-month")
        )
    }

    private func rateLimitWindows(token: String) async throws -> [LimitWindow] {
        var request = URLRequest(url: NVIDIANIMRateLimits.modelsEndpoint)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw UsageProviderError.timedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UsageProviderError.apiError(L10n.t("Couldn't reach NVIDIA NIM. Check your connection."))
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        if status == 429 {
            throw UsageProviderError.rateLimited(
                retryAfter: NVIDIANIMRateLimits.retryAfter(from: http) ?? 60
            )
        }
        guard (200..<300).contains(status), let http else {
            throw UsageProviderError.badResponse(status: status)
        }
        return NVIDIANIMRateLimits.windows(from: http)
    }
}

enum NVIDIANIMRateLimits {
    static let modelsEndpoint = URL(string: "https://integrate.api.nvidia.com/v1/models")!

    static func windows(from response: HTTPURLResponse, now: Date = Date()) -> [LimitWindow] {
        [
            window(
                id: "tokens",
                label: "NVIDIA API tokens",
                limit: response.value(forHTTPHeaderField: "x-ratelimit-limit-tokens"),
                remaining: response.value(forHTTPHeaderField: "x-ratelimit-remaining-tokens"),
                reset: response.value(forHTTPHeaderField: "x-ratelimit-reset-tokens"),
                now: now
            ),
            window(
                id: "requests",
                label: "NVIDIA API requests",
                limit: response.value(forHTTPHeaderField: "x-ratelimit-limit-requests"),
                remaining: response.value(forHTTPHeaderField: "x-ratelimit-remaining-requests"),
                reset: response.value(forHTTPHeaderField: "x-ratelimit-reset-requests"),
                now: now
            )
        ].compactMap { $0 }
    }

    static func retryAfter(from response: HTTPURLResponse?, now: Date = Date()) -> TimeInterval? {
        guard let header = response?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }

    private static func window(
        id: String,
        label: String,
        limit: String?,
        remaining: String?,
        reset: String?,
        now: Date
    ) -> LimitWindow? {
        guard let limit = Int(limit ?? ""), let remaining = Int(remaining ?? ""), limit > 0 else {
            return nil
        }
        let used = max(0, limit - remaining)
        return LimitWindow(
            id: id,
            label: label,
            usedFraction: Double(used) / Double(limit),
            remaining: max(0, remaining),
            used: used,
            detail: "\(LimitWindow.compact(used)) used · \(LimitWindow.compact(max(0, remaining))) left",
            resetsAt: resetDate(reset, now: now)
        )
    }

    private static func resetDate(_ value: String?, now: Date) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let number = TimeInterval(value)
        else { return nil }
        return number > 1_000_000_000
            ? Date(timeIntervalSince1970: number)
            : now.addingTimeInterval(number)
    }
}
