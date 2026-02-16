import SwiftUI
import Charts

struct ChartsView: View {
    @EnvironmentObject private var repository: AppRepository

    @State private var range: ChartRange = .month
    @State private var showTrend = true
    @State private var zoomDays: Double = 30
    @State private var selectedDate: Date?

    var body: some View {
        let filteredLogs = repository.logs(in: range).sorted(by: { $0.timestamp < $1.timestamp })
        let movingAverage = repository.movingAverage(for: filteredLogs, window: 7)
        let unit = repository.settings.defaultUnit

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Weight Trends")
                    .font(.largeTitle.bold())
                    .foregroundStyle(AppTheme.textPrimary)

                HStack(spacing: 8) {
                    ForEach(ChartRange.allCases) { option in
                        Button(option.rawValue) {
                            range = option
                            zoomDays = min(zoomDays, Double(option.days == Int.max ? 365 : option.days))
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(option == range ? AppTheme.accent : AppTheme.surface)
                        .foregroundStyle(option == range ? .black : AppTheme.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                Chart {
                    ForEach(filteredLogs) { log in
                        LineMark(
                            x: .value("Date", log.timestamp),
                            y: .value("Weight", repository.convertedWeight(log, to: unit))
                        )
                        .foregroundStyle(AppTheme.accent)
                        .interpolationMethod(.catmullRom)

                        PointMark(
                            x: .value("Date", log.timestamp),
                            y: .value("Weight", repository.convertedWeight(log, to: unit))
                        )
                        .foregroundStyle(AppTheme.accent)
                    }

                    if showTrend {
                        ForEach(movingAverage, id: \.0) { entry in
                            LineMark(
                                x: .value("Date", entry.0),
                                y: .value("7d avg", entry.1)
                            )
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 5]))
                            .interpolationMethod(.catmullRom)
                        }
                    }

                    if let selected = selectedLog(from: filteredLogs) {
                        RuleMark(x: .value("Selected", selected.timestamp))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .frame(height: 300)
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: zoomDomainLength)
                .chartXSelection(value: $selectedDate)
                .chartYAxisLabel("\(unit.label)")
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(AppTheme.surface)
                )

                HStack {
                    Text("Zoom")
                        .foregroundStyle(AppTheme.textSecondary)
                    Slider(value: $zoomDays, in: 7...365, step: 1)
                        .tint(AppTheme.accent)
                    Text("\(Int(zoomDays))d")
                        .foregroundStyle(AppTheme.textPrimary)
                        .font(.caption.monospacedDigit())
                }

                Toggle("Show 7-day trend", isOn: $showTrend)
                    .tint(AppTheme.accent)
                    .foregroundStyle(AppTheme.textPrimary)

                if let selected = selectedLog(from: filteredLogs) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(DateFormatting.shortDateTime.string(from: selected.timestamp))
                            .font(.headline)
                            .foregroundStyle(AppTheme.textPrimary)

                        Text(String(format: "%.1f %@", repository.convertedWeight(selected, to: unit), unit.label))
                            .font(.title3.bold())
                            .foregroundStyle(AppTheme.accent)

                        if let note = repository.note(for: selected) {
                            Text(note.text)
                                .font(.body)
                                .foregroundStyle(AppTheme.textSecondary)
                        } else {
                            Text("No note linked to this entry.")
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppTheme.surface)
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("AI Analysis")
                        .font(.headline)
                        .foregroundStyle(AppTheme.textPrimary)

                    Text("Coming soon: deeper pattern analysis from your weight trajectory and notes.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)

                    Text("Tip: Export JSON from Settings and upload it to your favorite AI chatbot for deeper analysis of trends, notes, and correlations.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.surface)
                )
            }
            .padding(16)
        }
        .background(AppTheme.background.ignoresSafeArea())
    }

    private var zoomDomainLength: TimeInterval {
        TimeInterval(max(7, zoomDays) * 24 * 60 * 60)
    }

    private func selectedLog(from logs: [WeightLog]) -> WeightLog? {
        guard let selectedDate else { return nil }
        return logs.min(by: { abs($0.timestamp.timeIntervalSince(selectedDate)) < abs($1.timestamp.timeIntervalSince(selectedDate)) })
    }
}
