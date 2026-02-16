import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var repository: AppRepository

    @State private var defaultUnit: WeightUnit = .lbs
    @State private var reminderEnabled = true
    @State private var reminderTime = Calendar.current.date(from: DateComponents(hour: 7, minute: 0)) ?? Date()

    @State private var birthday: Date?
    @State private var gender: Gender = .undisclosed
    @State private var heightFeet = ""
    @State private var heightInches = ""
    @State private var avatarPath: String?

    @State private var avatarImage: Image?
    @State private var selectedPhoto: PhotosPickerItem?

    @State private var showImporter = false
    @State private var showExporter = false
    @State private var showJSONExporter = false

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                preferencesSection
                dataSection
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle("Settings")
            .onAppear(perform: loadState)
            .onChange(of: defaultUnit) { _, _ in savePreferences() }
            .onChange(of: reminderEnabled) { _, _ in savePreferences() }
            .onChange(of: reminderTime) { _, _ in savePreferences() }
            .onChange(of: gender) { _, _ in saveProfile() }
            .onChange(of: heightFeet) { _, _ in saveProfile() }
            .onChange(of: heightInches) { _, _ in saveProfile() }
            .onChange(of: selectedPhoto) { _, newValue in
                guard let newValue else { return }
                Task {
                    await loadAvatar(from: newValue)
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.commaSeparatedText, .text],
                allowsMultipleSelection: false
            ) { result in
                guard case let .success(urls) = result, let url = urls.first else { return }
                do {
                    let data = try Data(contentsOf: url)
                    repository.importCSV(from: data)
                } catch {
                    repository.lastErrorMessage = "Unable to read CSV: \(error.localizedDescription)"
                }
            }
            .fileExporter(
                isPresented: $showExporter,
                document: CSVExportDocument(data: repository.exportCSV()),
                contentType: .commaSeparatedText,
                defaultFilename: "weighin-export"
            ) { result in
                if case let .failure(error) = result {
                    repository.lastErrorMessage = "Unable to export CSV: \(error.localizedDescription)"
                }
            }
            .fileExporter(
                isPresented: $showJSONExporter,
                document: JSONExportDocument(data: repository.exportJSON()),
                contentType: .json,
                defaultFilename: "weighin-export"
            ) { result in
                if case let .failure(error) = result {
                    repository.lastErrorMessage = "Unable to export JSON: \(error.localizedDescription)"
                }
            }
        }
    }

    private var profileSection: some View {
        Section("Profile") {
            HStack(spacing: 14) {
                avatarView

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Text("Choose Photo")
                }
                .buttonStyle(.bordered)
            }

            if birthday != nil {
                DatePicker(
                    "Birthday",
                    selection: Binding(
                        get: { birthday ?? Date() },
                        set: { value in
                            birthday = value
                            saveProfile()
                        }
                    ),
                    displayedComponents: .date
                )

                Button("Remove Birthday", role: .destructive) {
                    birthday = nil
                    saveProfile()
                }
            } else {
                Button("Set Birthday") {
                    birthday = Date()
                    saveProfile()
                }
            }

            Picker("Gender", selection: $gender) {
                ForEach(Gender.allCases, id: \.self) { item in
                    Text(item.label).tag(item)
                }
            }

            HStack {
                TextField("ft", text: $heightFeet)
                    .keyboardType(.numberPad)
                Text("ft")
                TextField("in", text: $heightInches)
                    .keyboardType(.numberPad)
                Text("in")
            }
        }
    }

    private var preferencesSection: some View {
        Section("Preferences") {
            Picker("Default Unit", selection: $defaultUnit) {
                Text("lbs").tag(WeightUnit.lbs)
                Text("kg").tag(WeightUnit.kg)
            }

            Toggle("Daily Reminder", isOn: $reminderEnabled)

            if reminderEnabled {
                DatePicker("Reminder Time", selection: $reminderTime, displayedComponents: .hourAndMinute)
            }
        }
    }

    private var dataSection: some View {
        Section("Data") {
            Button("Import CSV") {
                showImporter = true
            }

            Button("Export CSV") {
                showExporter = true
            }

            Button("Export JSON") {
                showJSONExporter = true
            }

            Text("Tip: Export JSON and upload it to your favorite AI chatbot for a deeper analysis of trends, notes, and correlations.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        if let avatarImage {
            avatarImage
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(AppTheme.surface)
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "person.fill")
                        .foregroundStyle(AppTheme.textSecondary)
                }
        }
    }

    private func loadState() {
        defaultUnit = repository.settings.defaultUnit
        reminderEnabled = repository.settings.reminderEnabled
        reminderTime = Calendar.current.date(from: DateComponents(
            hour: repository.settings.reminderHour,
            minute: repository.settings.reminderMinute
        )) ?? Date()

        birthday = repository.profile.birthday
        gender = repository.profile.gender
        avatarPath = repository.profile.avatarPath

        if let heightCm = repository.profile.heightCentimeters {
            let totalInches = Int(round(heightCm / 2.54))
            heightFeet = String(totalInches / 12)
            heightInches = String(totalInches % 12)
        } else {
            heightFeet = ""
            heightInches = ""
        }

        loadAvatarFromDisk()
    }

    private func savePreferences() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        let hour = parts.hour ?? 7
        let minute = parts.minute ?? 0

        let updated = AppSettings(
            defaultUnit: defaultUnit,
            reminderEnabled: reminderEnabled,
            reminderHour: hour,
            reminderMinute: minute,
            hasCompletedOnboarding: repository.settings.hasCompletedOnboarding
        )

        guard updated != repository.settings else { return }
        repository.updateSettings(updated)
    }

    private func saveProfile() {
        let feet = Int(heightFeet) ?? 0
        let inches = Int(heightInches) ?? 0
        let heightCentimeters: Double?
        if feet == 0 && inches == 0 {
            heightCentimeters = nil
        } else {
            heightCentimeters = Double((feet * 12) + inches) * 2.54
        }

        let updated = UserProfile(
            birthday: birthday,
            gender: gender,
            heightCentimeters: heightCentimeters,
            avatarPath: avatarPath
        )

        guard updated != repository.profile else { return }
        repository.updateProfile(updated)
    }

    private func loadAvatar(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data) else {
            return
        }

        avatarImage = Image(uiImage: uiImage)
        avatarPath = storeAvatar(data)
        saveProfile()
    }

    private func storeAvatar(_ data: Data) -> String? {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = root.appendingPathComponent("WeighIn", isDirectory: true)
        let fileURL = directory.appendingPathComponent("profile-avatar.jpg")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            repository.lastErrorMessage = "Could not save profile image: \(error.localizedDescription)"
            return nil
        }
    }

    private func loadAvatarFromDisk() {
        guard let avatarPath,
              let image = UIImage(contentsOfFile: avatarPath) else {
            avatarImage = nil
            return
        }

        avatarImage = Image(uiImage: image)
    }
}

private struct CSVExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .text] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct JSONExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
