import SwiftUI

struct LogView: View {
    @EnvironmentObject private var repository: AppRepository
    @StateObject private var model = LogViewModel()
    @State private var editingLog: WeightLog?
    @State private var pendingDeleteLog: WeightLog?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                keypadSection
                recentLogsSection
                notesSection
                actionSection
            }
            .padding(16)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .sheet(isPresented: $model.showingPastEntry) {
            PastEntrySheet()
                .environmentObject(repository)
        }
        .sheet(item: $editingLog) { log in
            EditLogSheet(log: log)
                .environmentObject(repository)
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

    private var header: some View {
        VStack(spacing: 8) {
            Text(DateFormatting.shortDate.string(from: Date()))
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)

            Text(weightDisplay)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(AppTheme.surface)
                )

            Button {
                model.saveCurrent(using: repository)
            } label: {
                Text("Save Now")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(model.parsedWeight == nil)
            .opacity(model.parsedWeight == nil ? 0.4 : 1)
        }
    }

    private var keypadSection: some View {
        NumericKeypad { key in
            model.handleKey(key)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.25))
        )
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)

            Text("How was yesterday? Sleep, food, exercise, stress, mood.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)

            TextEditor(text: $model.noteInput)
                .frame(minHeight: 130)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppTheme.accentMuted.opacity(0.5), lineWidth: 1)
                )
        }
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
                ForEach(Array(repository.logs.prefix(8))) { log in
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

                            Text(log.source.rawValue.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(AppTheme.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(AppTheme.accentMuted.opacity(0.35))
                                )

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
                            .fill(AppTheme.surface)
                    )
                }
            }
        }
    }

    private var actionSection: some View {
        VStack(spacing: 10) {
            Button {
                model.saveCurrent(using: repository)
            } label: {
                Text("Save Weight + Note")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.surface)
                    .foregroundStyle(AppTheme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(model.parsedWeight == nil)

            Button {
                model.saveNoteOnly(using: repository)
            } label: {
                Text("Save Note Only")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.surface)
                    .foregroundStyle(AppTheme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(model.noteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                model.showingPastEntry = true
            } label: {
                Text("Log Past Entry")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.accentMuted)
                    .foregroundStyle(AppTheme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var weightDisplay: String {
        let value = model.weightInput.isEmpty ? "--" : model.weightInput
        return "\(value) \(repository.settings.defaultUnit.label)"
    }
}

private struct EditLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repository: AppRepository

    let log: WeightLog

    @State private var entryDate: Date
    @State private var weightInput: String
    @State private var noteInput: String = ""

    init(log: WeightLog) {
        self.log = log
        _entryDate = State(initialValue: log.timestamp)
        _weightInput = State(initialValue: String(format: "%.1f", log.weight))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date & Time") {
                    DatePicker("When", selection: $entryDate)
                }

                Section("Weight") {
                    HStack {
                        TextField("e.g. 182.4", text: $weightInput)
                            .keyboardType(.decimalPad)
                        Text(log.unit.label)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Note") {
                    TextEditor(text: $noteInput)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle("Edit Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(Double(weightInput) == nil)
                }
            }
            .onAppear {
                noteInput = repository.note(for: log)?.text ?? ""
            }
        }
    }

    private func save() {
        guard let weight = Double(weightInput), weight > 0 else { return }
        repository.updateWeightLog(log, weight: weight, timestamp: entryDate, noteText: noteInput)
        dismiss()
    }
}
