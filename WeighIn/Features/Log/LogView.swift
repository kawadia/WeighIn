import SwiftUI

struct LogView: View {
    @EnvironmentObject private var repository: AppRepository
    @StateObject private var model = LogViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                keypadSection
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
