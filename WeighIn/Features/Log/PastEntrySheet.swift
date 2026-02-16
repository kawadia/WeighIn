import SwiftUI

struct PastEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repository: AppRepository

    @State private var entryDate = Date()
    @State private var weightInput = ""
    @State private var noteInput = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Date & Time") {
                    DatePicker("When", selection: $entryDate)
                }

                Section("Weight") {
                    TextField("e.g. 182.4", text: $weightInput)
                        .keyboardType(.decimalPad)
                }

                Section("Note") {
                    TextEditor(text: $noteInput)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle("Log Past Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savePastEntry()
                    }
                    .disabled(Double(weightInput) == nil)
                }
            }
        }
    }

    private func savePastEntry() {
        guard let weight = Double(weightInput), weight > 0 else { return }

        repository.addWeightLog(
            weight: weight,
            timestamp: entryDate,
            noteText: noteInput,
            source: .past
        )

        dismiss()
    }
}
