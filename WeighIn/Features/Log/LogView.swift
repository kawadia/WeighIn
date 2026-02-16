import SwiftUI

struct LogView: View {
    @EnvironmentObject private var repository: AppRepository
    @StateObject private var model = LogViewModel()
    @State private var editingLog: WeightLog?
    @State private var pendingDeleteLog: WeightLog?
    @FocusState private var noteEditorFocused: Bool

    var body: some View {
        GeometryReader { _ in
            ScrollView {
                VStack(spacing: 12) {
                    titleBar

                    EntryEditorCard(
                        weightText: model.weightInput.isEmpty ? "--" : model.weightInput,
                        unitLabel: repository.settings.defaultUnit.label,
                        timestamp: $model.entryTimestamp,
                        noteInput: $model.noteInput,
                        noteFocused: $noteEditorFocused,
                        saveTitle: "Save Entry",
                        saveEnabled: model.parsedWeight != nil,
                        statusMessage: model.lastSaveMessage.isEmpty ? " " : model.lastSaveMessage,
                        onKeyTap: { key in
                            model.handleKey(key)
                        },
                        onSave: {
                            model.saveUnifiedEntry(using: repository)
                            noteEditorFocused = false
                        }
                    ) {
                        VStack(spacing: 8) {
                            HStack {
                                Spacer()

                                Label(
                                    model.isVoiceRecording ? "Listening…" : "Hold to Talk",
                                    systemImage: model.isVoiceRecording ? "waveform" : "mic.fill"
                                )
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(model.isVoiceRecording ? .black : AppTheme.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(model.isVoiceRecording ? Color.red.opacity(0.9) : AppTheme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { _ in
                                            model.beginVoiceCapturePress()
                                        }
                                        .onEnded { _ in
                                            model.endVoiceCapturePress()
                                        }
                                )
                                .accessibilityLabel("Hold to talk")

                                Spacer()
                            }

                            if model.isVoiceRecording || !model.liveVoiceTranscript.isEmpty {
                                Text(model.liveVoiceTranscript.isEmpty ? "Listening…" : model.liveVoiceTranscript)
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

                    recentLogsSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 24)
                .onTapGesture {
                    noteEditorFocused = false
                }
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .sheet(item: $editingLog) { log in
            EditLogSheet(log: log)
                .environmentObject(repository)
        }
        .onDisappear {
            model.stopVoiceRecordingIfNeeded()
        }
        .alert("Delete entry?", isPresented: Binding(
            get: { pendingDeleteLog != nil },
            set: { newValue in
                if !newValue {
                    pendingDeleteLog = nil
                }
            }
        )) {
            Button("Delete", role: .destructive) {
                guard let log = pendingDeleteLog else { return }
                repository.deleteWeightLog(log)
                pendingDeleteLog = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteLog = nil
            }
        } message: {
            Text("This will remove the weight log and its linked note.")
        }
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)

            Text("Weigh & Reflect")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 138 / 255, green: 246 / 255, blue: 171 / 255), AppTheme.accent],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .shadow(color: AppTheme.accent.opacity(0.2), radius: 8, x: 0, y: 2)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 4)
    }

    private var recentLogsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Logs")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)

            if repository.logs.isEmpty {
                Text("No entries yet.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppTheme.surface)
                    )
            } else {
                ForEach(Array(repository.logs.prefix(5))) { log in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(
                                String(
                                    format: "%.1f %@",
                                    repository.convertedWeight(log, to: repository.settings.defaultUnit),
                                    repository.settings.defaultUnit.label
                                )
                            )
                            .font(.headline)
                            .foregroundStyle(AppTheme.textPrimary)

                            if log.source != .manual {
                                Text(log.source.rawValue.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(AppTheme.accentMuted.opacity(0.35))
                                    )
                            }

                            Spacer()

                            Button {
                                editingLog = log
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .foregroundStyle(AppTheme.accent)

                            Button(role: .destructive) {
                                pendingDeleteLog = log
                            } label: {
                                Image(systemName: "trash")
                            }
                            .foregroundStyle(.red.opacity(0.85))
                        }

                        Text(DateFormatting.shortDateTime.string(from: log.timestamp))
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)

                        if let note = repository.note(for: log), !note.text.isEmpty {
                            Text(note.text)
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppTheme.background.opacity(0.35))
                    )
                }
            }
        }
        .padding(14)
        .background(sectionCardBackground)
        .overlay(sectionCardBorder)
    }

    private var sectionCardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(AppTheme.surface.opacity(0.35))
    }

    private var sectionCardBorder: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(AppTheme.accentMuted.opacity(0.28), lineWidth: 1)
    }
}

private struct EntryEditorCard<Accessory: View>: View {
    let weightText: String
    let unitLabel: String
    @Binding var timestamp: Date
    @Binding var noteInput: String
    var noteFocused: FocusState<Bool>.Binding
    let saveTitle: String
    let saveEnabled: Bool
    let statusMessage: String?
    let onKeyTap: (String) -> Void
    let onSave: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(weightText) \(unitLabel)")
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.surface)
                )

            NumericKeypad { key in
                onKeyTap(key)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.25))
            )

            HStack(spacing: 8) {
                dateSelectorChip
                timeSelectorChip
            }
            .frame(maxWidth: .infinity, alignment: .center)

            ReflectionNotePanel(
                noteInput: $noteInput,
                noteFocused: noteFocused,
                saveTitle: saveTitle,
                saveEnabled: saveEnabled,
                statusMessage: statusMessage,
                onSave: onSave
            ) {
                accessory()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppTheme.surface.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.accentMuted.opacity(0.28), lineWidth: 1)
        )
    }

    private var dateSelectorChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .foregroundStyle(AppTheme.textSecondary)

            DatePicker(
                "",
                selection: $timestamp,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(AppTheme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.surface)
        )
    }

    private var timeSelectorChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .foregroundStyle(AppTheme.textSecondary)

            DatePicker(
                "",
                selection: $timestamp,
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(AppTheme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.surface)
        )
    }
}

struct ReflectionNotePanel<Accessory: View>: View {
    @Binding var noteInput: String
    var noteFocused: FocusState<Bool>.Binding
    let saveTitle: String
    let saveEnabled: Bool
    let statusMessage: String?
    let onSave: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $noteInput)
                    .focused(noteFocused)
                    .padding(6)

                if noteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("How was your day? Sleep, food, exercise, stress, mood, and anything else.\nAdd a quick reflection to improve future analysis quality.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.55))
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 132)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.accentMuted.opacity(0.5), lineWidth: 1)
            )

            accessory()

            Button {
                onSave()
            } label: {
                Text(saveTitle)
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(!saveEnabled)
            .opacity(saveEnabled ? 1 : 0.4)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
        }
    }
}

private struct EditLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repository: AppRepository

    let log: WeightLog

    @State private var entryDate: Date
    @State private var weightInput: String
    @State private var noteInput: String = ""
    @FocusState private var noteEditorFocused: Bool

    init(log: WeightLog) {
        self.log = log
        _entryDate = State(initialValue: log.timestamp)
        _weightInput = State(initialValue: String(format: "%.1f", log.weight))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                EntryEditorCard(
                    weightText: weightInput.isEmpty ? "--" : weightInput,
                    unitLabel: log.unit.label,
                    timestamp: $entryDate,
                    noteInput: $noteInput,
                    noteFocused: $noteEditorFocused,
                    saveTitle: "Update",
                    saveEnabled: Double(weightInput) != nil,
                    statusMessage: nil,
                    onKeyTap: { key in
                        handleKey(key)
                    },
                    onSave: {
                        save()
                    }
                ) {
                    EmptyView()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .onTapGesture {
                    noteEditorFocused = false
                }
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Edit Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                noteInput = repository.note(for: log)?.text ?? ""
            }
        }
    }

    private func handleKey(_ key: String) {
        switch key {
        case "⌫":
            guard !weightInput.isEmpty else { return }
            weightInput.removeLast()
        case ".":
            guard !weightInput.contains(".") else { return }
            weightInput = weightInput.isEmpty ? "0." : weightInput + "."
        default:
            guard weightInput.count < 7 else { return }
            if key == "0", weightInput == "0" {
                return
            }
            if weightInput == "0" {
                weightInput = key
            } else {
                weightInput.append(key)
            }
        }
    }

    private func save() {
        guard let weight = Double(weightInput), weight > 0 else { return }
        repository.updateWeightLog(log, weight: weight, timestamp: entryDate, noteText: noteInput)
        noteEditorFocused = false
        dismiss()
    }
}
