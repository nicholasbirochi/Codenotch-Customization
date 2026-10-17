import SwiftUI

/// One fixed geometry for every period, including empty/offline histories.
struct ObservedUsageSection: View {
    let history: ObservedUsageHistory
    var now: Date
    @AppStorage private var periodRaw: String
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    init(history: ObservedUsageHistory, providerID: String, defaults: UserDefaults = .standard, now: Date = Date()) {
        self.history = history
        self.now = now
        _periodRaw = AppStorage(wrappedValue: UsageHistoryPeriod.month.rawValue,
                               UsageHistoryPeriod.preferenceKey(providerID), store: defaults)
    }

    private var period: UsageHistoryPeriod { UsageHistoryPeriod(rawValue: periodRaw) ?? .month }
    private var slice: ObservedUsageHistory.Slice { history.slice(period) }
    private var unavailable: Bool { history.unavailable || !history.isCurrent(period, now: now) }
    private var bars: [CodexTokenUsage.DailyBucket] {
        slice.buckets.map { .init(startDate: String($0.at.timeIntervalSince1970), tokens: $0.tokens) }
    }
    private func value(_ number: Int?) -> String { unavailable ? "—" : UsageFormat.tokens(number) }
    private func row(_ name: String, _ value: String) -> some View {
        SplitRow(leading: name, trailing: value).frame(height: NotchLayout.cardBodyLineHeight)
    }
    private var divider: some View {
        Rectangle().fill(Palette.ringTrack).frame(height: NotchLayout.hairline)
            .padding(.vertical, NotchLayout.codexUsageRowGap)
    }
    private func stamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(slice.hourly ? .dateTime.hour(.twoDigits(amPM: .omitted)) : .dateTime.day().month())
    }

    private var periodPicker: some View {
        HStack(spacing: Design.px(18)) {
            ForEach(UsageHistoryPeriod.allCases) { option in
                Button { periodRaw = option.rawValue } label: {
                    Text(option.title)
                        .font(option == period ? Typography.cardBody.weight(.semibold) : Typography.cardBody)
                        .foregroundStyle(option == period ? Palette.textPrimary : secondaryInk)
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(option == period ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.frame(height: NotchLayout.cardBodyLineHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if history.unavailable {
                divider
                periodPicker
                Text(history.note(period: period)).font(Typography.cardBody)
                    .foregroundStyle(secondaryInk).lineLimit(2)
                    .frame(height: 2 * NotchLayout.cardBodyLineHeight, alignment: .topLeading)
                divider
                Text(L10n.t("Most used projects")).font(Typography.cardBody.weight(.semibold))
                    .frame(height: NotchLayout.cardBodyLineHeight)
                row(L10n.t("Project attribution unavailable"), "—")
            } else {
                divider
                row(L10n.t("Total observed"), value(history.observedTotal))
                row(L10n.t("Observed requests"), value(history.observedRequests))
                if history.source == .openCode {
                    row(slice.hourly ? L10n.t("Peak hour in period") : L10n.t("Peak day in period"), value(slice.peak))
                }
                row(L10n.t("Input / output in period"), "\(value(slice.input)) / \(value(slice.output))")
                if history.source == .openCode {
                    Text(history.model.map { L10n.t("Top model this month: \($0)") } ?? history.sourceTitle)
                        .font(Typography.cardBody).foregroundStyle(secondaryInk).lineLimit(1)
                        .frame(height: NotchLayout.cardBodyLineHeight)
                }
                divider
                periodPicker
                row(L10n.t("Tokens in period"), value(slice.total))
                Group {
                    if unavailable {
                        Text(L10n.t("Event history unavailable"))
                            .font(Typography.cardBody).foregroundStyle(secondaryInk)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        CodexDailyUsageChart(buckets: bars, maximum: max(1, slice.peak))
                            .accessibilityLabel(L10n.t("Observed token history"))
                            .accessibilityValue(value(slice.total))
                    }
                }.frame(height: NotchLayout.codexChartHeight)
                    .padding(.top, NotchLayout.codexChartTop)
                row(stamp(slice.buckets.first?.at), stamp(slice.buckets.last?.at))
                Text(!history.unavailable && unavailable ? L10n.t("History is from an earlier period. Waiting for a new reading.") : history.note(period: period))
                    .font(Typography.cardBody).foregroundStyle(secondaryInk).lineLimit(2)
                    .frame(height: 2 * NotchLayout.cardBodyLineHeight, alignment: .topLeading)
                divider
                Text(L10n.t("Most used projects")).font(Typography.cardBody.weight(.semibold))
                    .frame(height: NotchLayout.cardBodyLineHeight)
                ForEach(0..<history.projectRowCount, id: \.self) { index in
                    Group {
                        if index < slice.projects.count, !unavailable {
                            let project = slice.projects[index]
                            row(project.title, "\(Percent.text(for: slice.total > 0 ? Double(project.tokens) / Double(slice.total) : 0))% · \(UsageFormat.tokens(project.tokens))")
                        } else if index == 0 {
                            row(unavailable ? L10n.t("Project attribution unavailable") : L10n.t("No observed activity in period"), "—")
                        } else { Color.clear }
                    }.frame(height: NotchLayout.cardBodyLineHeight)
                }
            }
        }.frame(height: NotchLayout.observedUsageHeight(history), alignment: .topLeading)
    }
}
