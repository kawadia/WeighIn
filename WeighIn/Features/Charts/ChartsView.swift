import SwiftUI
import Charts
import UniformTypeIdentifiers

struct ChartsView: View {
    @EnvironmentObject private var repository: AppRepository
    @StateObject private var voiceModel = LogViewModel(shouldPersistDraft: false)

    @State private var range: ChartRange = .month
    @State private var showTrend = true
    @State private var zoomDays: Double = 30
    @State private var selectedDate: Date?
    @State private var selectedLogID: String?
    @State private var noteDraft = ""
    @State private var noteSaveMessage: String?
    @State private var isEditingSelectedNote = false
    @State private var scrollPosition: Date = Date()
    @FocusState private var noteFocused: Bool

    var body: some View {
        let filteredLogs = repository.logs(in: range).sorted(by: { $0.timestamp < $1.timestamp })
        let movingAverage = repository.movingAverage(for: filteredLogs, window: 7)
        let plottedSeries = smoothedSeries(from: filteredLogs)
        let canShowPoints = zoomDays <= 120
        let unit = repository.settings.defaultUnit
        let maxZoom = maxZoomDays(for: filteredLogs)
        let sliderUpperBound = max(maxZoom, 8)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Weight Trends")
                    .font(.largeTitle.bold())
                    .foregroundStyle(AppTheme.textPrimary)

                HStack(spacing: 8) {
                    ForEach(ChartRange.allCases) { option in
                        Button(option.rawValue) {
                            range = option
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
                    ForEach(plottedSeries, id: \.timestamp) { point in
                        LineMark(
                            x: .value("Date", point.timestamp),
                            y: .value("Weight", point.weight)
                        )
                        .foregroundStyle(AppTheme.accent)
                        .interpolationMethod(.catmullRom)
                    }

                    if canShowPoints {
                        ForEach(filteredLogs) { log in
                            PointMark(
                                x: .value("Date", log.timestamp),
                                y: .value("Weight", repository.convertedWeight(log, to: unit))
                            )
                            .foregroundStyle(AppTheme.accent)
                        }
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

                    if let selected = selectedLog(in: filteredLogs) {
                        RuleMark(x: .value("Selected", selected.timestamp))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .frame(height: 300)
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: zoomDomainLength)
                .chartScrollPosition(x: $scrollPosition)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                SpatialTapGesture()
                                    .onEnded { value in
                                        guard let plotFrame = proxy.plotFrame else { return }
                                        let plotRect = geometry[plotFrame]
                                        let xInPlot = value.location.x - plotRect.origin.x

                                        guard xInPlot >= 0, xInPlot <= proxy.plotSize.width else { return }
                                        guard let tappedDate = proxy.value(atX: xInPlot, as: Date.self) else { return }

                                        selectedDate = tappedDate
                                        noteFocused = false
                                    }
                            )
                    }
                }
                .chartYAxisLabel("\(unit.label)")
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(AppTheme.surface)
                )

                HStack {
                    Text("Zoom")
                        .foregroundStyle(AppTheme.textSecondary)
                    Slider(value: $zoomDays, in: 7...sliderUpperBound, step: 1)
                        .tint(AppTheme.accent)
                    Text("\(Int(zoomDays))d")
                        .foregroundStyle(AppTheme.textPrimary)
                        .font(.caption.monospacedDigit())
                }

                Toggle("Show 7-day trend", isOn: $showTrend)
                    .tint(AppTheme.accent)
                    .foregroundStyle(AppTheme.textPrimary)

                if let selected = selectedLog(in: filteredLogs) {
                    VStack(alignment: .leading, spacing: 6) {
                        let existingNoteText = repository.note(for: selected)?
                            .text
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(format: "%.1f %@", repository.convertedWeight(selected, to: unit), unit.label))
                                .font(.title3.bold())
                                .foregroundStyle(AppTheme.accent)

                            Text(DateFormatting.shortDateTime.string(from: selected.timestamp))
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                        }

                        if let existingNoteText,
                           !existingNoteText.isEmpty,
                           !isEditingSelectedNote {
                            Text(existingNoteText)
                                .font(.body)
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(AppTheme.background.opacity(0.45))
                                )

                            HStack {
                                Button("Edit Note") {
                                    beginEditingSelectedNote(existingNoteText)
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(AppTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                Spacer()
                            }
                        } else {
                            ReflectionNotePanel(
                                noteInput: $noteDraft,
                                noteFocused: $noteFocused,
                                saveTitle: "Save Note",
                                saveEnabled: true,
                                statusMessage: trendsStatusMessage,
                                onSave: {
                                    saveNote(for: selected)
                                }
                            ) {
                                VStack(spacing: 8) {
                                    HStack {
                                        Spacer()

                                        Label(
                                            voiceModel.isVoiceRecording ? "Listening…" : "Hold to Talk",
                                            systemImage: voiceModel.isVoiceRecording ? "waveform" : "mic.fill"
                                        )
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(voiceModel.isVoiceRecording ? .black : AppTheme.textPrimary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(voiceModel.isVoiceRecording ? Color.red.opacity(0.9) : AppTheme.surface)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .gesture(
                                            DragGesture(minimumDistance: 0)
                                                .onChanged { _ in
                                                    beginVoiceCaptureForSelectedNote()
                                                }
                                                .onEnded { _ in
                                                    endVoiceCaptureForSelectedNote()
                                                }
                                        )
                                        .accessibilityLabel("Hold to talk")

                                        Spacer()
                                    }

                                    if voiceModel.isVoiceRecording || !voiceModel.liveVoiceTranscript.isEmpty {
                                        Text(voiceModel.liveVoiceTranscript.isEmpty ? "Listening…" : voiceModel.liveVoiceTranscript)
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.textSecondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 8)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .fill(AppTheme.surface)
                                            )
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppTheme.surface)
                    )
                }
            }
            .padding(16)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .onAppear {
            if let latest = filteredLogs.last {
                scrollPosition = latest.timestamp
            }
            syncSelection(with: filteredLogs)
            zoomDays = min(max(zoomDays, 7), maxZoom)
        }
        .onChange(of: range) { _, _ in
            zoomDays = min(max(zoomDays, 7), maxZoomDays(for: filteredLogs))
            syncSelection(with: filteredLogs)
        }
        .onChange(of: selectedDate) { _, _ in
            syncSelection(with: filteredLogs)
        }
        .onChange(of: filteredLogs.map(\.id)) { _, _ in
            zoomDays = min(max(zoomDays, 7), maxZoomDays(for: filteredLogs))
            syncSelection(with: filteredLogs)
        }
        .onChange(of: noteDraft) { _, newValue in
            if voiceModel.noteInput != newValue {
                voiceModel.noteInput = newValue
            }
        }
        .onChange(of: voiceModel.noteInput) { _, newValue in
            if noteDraft != newValue {
                noteDraft = newValue
            }
        }
        .onTapGesture {
            noteFocused = false
        }
        .onDisappear {
            voiceModel.stopVoiceRecordingIfNeeded()
        }
    }

    private var trendsStatusMessage: String {
        if let noteSaveMessage, !noteSaveMessage.isEmpty {
            return noteSaveMessage
        }
        if !voiceModel.lastSaveMessage.isEmpty {
            return voiceModel.lastSaveMessage
        }
        return "Tap any point to edit note context. Scroll and zoom to browse history. Leave note empty and save to remove."
    }

    private var zoomDomainLength: TimeInterval {
        TimeInterval(max(7, zoomDays) * 24 * 60 * 60)
    }

    private func selectedLog(in logs: [WeightLog]) -> WeightLog? {
        guard let selectedLogID else { return nil }
        return logs.first(where: { $0.id == selectedLogID })
    }

    private func syncSelection(with logs: [WeightLog]) {
        guard !logs.isEmpty else {
            selectedLogID = nil
            noteDraft = ""
            noteSaveMessage = nil
            isEditingSelectedNote = false
            return
        }

        guard let selectedDate else {
            selectedLogID = nil
            noteDraft = ""
            noteSaveMessage = nil
            isEditingSelectedNote = false
            return
        }

        guard let nearest = logs.min(by: {
            abs($0.timestamp.timeIntervalSince(selectedDate)) < abs($1.timestamp.timeIntervalSince(selectedDate))
        }) else {
            return
        }

        if selectedLogID != nearest.id {
            selectedLogID = nearest.id
            noteDraft = repository.note(for: nearest)?.text ?? ""
            voiceModel.noteInput = noteDraft
            noteSaveMessage = nil
            let existing = repository.note(for: nearest)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            isEditingSelectedNote = existing.isEmpty
        }
    }

    private func saveNote(for log: WeightLog) {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        repository.updateWeightLog(log, weight: log.weight, timestamp: log.timestamp, noteText: trimmed)
        noteSaveMessage = trimmed.isEmpty ? "Note removed." : "Note saved."
        isEditingSelectedNote = trimmed.isEmpty
        noteFocused = false
    }

    private func beginEditingSelectedNote(_ existingText: String) {
        noteDraft = existingText
        voiceModel.noteInput = existingText
        noteSaveMessage = nil
        isEditingSelectedNote = true
    }

    private func beginVoiceCaptureForSelectedNote() {
        voiceModel.noteInput = noteDraft
        voiceModel.beginVoiceCapturePress()
    }

    private func endVoiceCaptureForSelectedNote() {
        voiceModel.endVoiceCapturePress()
        noteDraft = voiceModel.noteInput
    }

    private func maxZoomDays(for logs: [WeightLog]) -> Double {
        guard let first = logs.first?.timestamp, let last = logs.last?.timestamp else {
            return 365
        }
        let span = max(7, ceil(last.timeIntervalSince(first) / 86_400))
        return min(3650, max(8, span))
    }

    private func smoothedSeries(from logs: [WeightLog]) -> [(timestamp: Date, weight: Double)] {
        guard !logs.isEmpty else { return [] }

        if zoomDays <= 120 {
            return logs.map { ($0.timestamp, repository.convertedWeight($0, to: repository.settings.defaultUnit)) }
        }

        if zoomDays <= 730 {
            return bucketedSeries(from: logs, components: [.year, .month, .day], to: .day)
        }

        if zoomDays <= 1825 {
            return bucketedSeries(from: logs, components: [.yearForWeekOfYear, .weekOfYear], to: .week)
        }

        return bucketedSeries(from: logs, components: [.year, .month], to: .month)
    }

    private enum BucketScale {
        case day
        case week
        case month
    }

    private func bucketedSeries(
        from logs: [WeightLog],
        components: Set<Calendar.Component>,
        to scale: BucketScale
    ) -> [(timestamp: Date, weight: Double)] {
        let calendar = Calendar.current
        var buckets: [DateComponents: [Double]] = [:]

        for log in logs {
            let key = calendar.dateComponents(components, from: log.timestamp)
            buckets[key, default: []].append(repository.convertedWeight(log, to: repository.settings.defaultUnit))
        }

        let mapped: [(Date, Double)] = buckets.compactMap { key, values in
            guard let bucketDate = bucketDate(from: key, scale: scale, calendar: calendar) else { return nil }
            let avg = values.reduce(0, +) / Double(values.count)
            return (bucketDate, avg)
        }

        return mapped.sorted(by: { $0.0 < $1.0 })
    }

    private func bucketDate(from components: DateComponents, scale: BucketScale, calendar: Calendar) -> Date? {
        switch scale {
        case .day:
            return calendar.date(from: DateComponents(
                year: components.year,
                month: components.month,
                day: components.day
            ))
        case .week:
            return calendar.date(from: DateComponents(
                weekOfYear: components.weekOfYear,
                yearForWeekOfYear: components.yearForWeekOfYear
            ))
        case .month:
            return calendar.date(from: DateComponents(
                year: components.year,
                month: components.month,
                day: 1
            ))
        }
    }
}

struct AIAnalysisView: View {
    @EnvironmentObject private var repository: AppRepository
    @State private var showJSONExporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("AI Analysis")
                    .font(.largeTitle.bold())
                    .foregroundStyle(AppTheme.textPrimary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Coming Soon")
                        .font(.headline)
                        .foregroundStyle(AppTheme.textPrimary)

                    Text("Deeper pattern analysis from your weight trajectory and reflections will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)

                    Text("Tip: Export JSON here (or from Settings) and upload it to your favorite AI chatbot for deep analysis of trends, notes, and correlations.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)

                    Text("JSON export includes your logs, linked notes, settings, and profile info.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.surface)
                )

                Button {
                    showJSONExporter = true
                } label: {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(16)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .fileExporter(
            isPresented: $showJSONExporter,
            document: AIJSONExportDocument(data: repository.exportJSON()),
            contentType: .json,
            defaultFilename: "weighin-export"
        ) { result in
            if case let .failure(error) = result {
                repository.lastErrorMessage = "Unable to export JSON: \(error.localizedDescription)"
            }
        }
    }
}

private struct AIJSONExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
