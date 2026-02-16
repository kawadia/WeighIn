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

    @State private var selectedImportFormat: DataTransferFormat = .csv
    @State private var selectedExportFormat: DataTransferFormat = .csv
    @State private var showImportFormatPicker = false
    @State private var showExportFormatPicker = false
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var showBackupFolderPicker = false
    @State private var showBackupRestoreImporter = false
    @State private var iCloudBackupEnabled = false

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                preferencesSection
                dataSection
                backupSection
                legalSection
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle("Settings")
            .onAppear(perform: loadState)
            .onChange(of: defaultUnit) { _, _ in savePreferences() }
            .onChange(of: reminderEnabled) { _, _ in savePreferences() }
            .onChange(of: reminderTime) { _, _ in savePreferences() }
            .onChange(of: iCloudBackupEnabled) { _, newValue in
                repository.setICloudBackupEnabled(newValue)
            }
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
                allowedContentTypes: selectedImportFormat.allowedImportTypes,
                allowsMultipleSelection: false
            ) { result in
                guard case let .success(urls) = result, let url = urls.first else { return }
                importData(from: url, format: selectedImportFormat)
            }
            .fileExporter(
                isPresented: $showExporter,
                document: BinaryExportDocument(data: exportData(for: selectedExportFormat)),
                contentType: selectedExportFormat.exportContentType,
                defaultFilename: selectedExportFormat.defaultExportFilename
            ) { result in
                if case let .failure(error) = result {
                    repository.lastErrorMessage = "Unable to export \(selectedExportFormat.label): \(error.localizedDescription)"
                }
            }
            .fileImporter(
                isPresented: $showBackupRestoreImporter,
                allowedContentTypes: [.sqliteDatabase, .sqliteDBFile, .sqlite3DBFile],
                allowsMultipleSelection: false
            ) { result in
                guard case let .success(urls) = result, let url = urls.first else { return }
                importData(from: url, format: .sqlite)
            }
            .sheet(isPresented: $showBackupFolderPicker) {
                BackupFolderPicker { folderURL in
                    repository.setBackupFolder(folderURL)
                }
            }
            .confirmationDialog("Import Format", isPresented: $showImportFormatPicker, titleVisibility: .visible) {
                ForEach(DataTransferFormat.importFormats) { format in
                    Button(format.label) {
                        selectedImportFormat = format
                        showImporter = true
                    }
                }
            }
            .confirmationDialog("Export Format", isPresented: $showExportFormatPicker, titleVisibility: .visible) {
                ForEach(DataTransferFormat.exportFormats) { format in
                    Button(format.label) {
                        selectedExportFormat = format
                        showExporter = true
                    }
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
            Button("Import") {
                showImportFormatPicker = true
            }

            Button("Export") {
                showExportFormatPicker = true
            }
        }
    }

    private var legalSection: some View {
        Section("Legal") {
            if let privacyPolicyURL = URL(string: "https://github.com/kawadia/WeighIn/blob/main/privacy_policy.txt") {
                Link(destination: privacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "doc.text")
                }
            }
        }
    }

    private var backupSection: some View {
        Section("iCloud Drive Backup") {
            Toggle("Enable Daily Backup", isOn: $iCloudBackupEnabled)

            Text("Creates a SQLite snapshot in your selected iCloud Drive folder once per day after midnight.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)

            Button("Choose Backup Folder") {
                showBackupFolderPicker = true
            }

            if let folderName = repository.backupFolderDisplayName() {
                Text("Folder: \(folderName)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                Text("No folder selected.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            if repository.backupInProgress {
                Label("Backing up…", systemImage: "externaldrive.badge.icloud")
                    .foregroundStyle(AppTheme.textSecondary)
            }

            if let lastBackupAt = repository.lastBackupAt {
                Text("Last backup: \(DateFormatting.shortDateTime.string(from: lastBackupAt))")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                Text("No successful backup yet.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            if let lastBackupError = repository.lastBackupError,
               !lastBackupError.isEmpty {
                Text(lastBackupError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button("Back Up Now") {
                repository.triggerBackupNow()
            }
            .disabled(!iCloudBackupEnabled || repository.backupInProgress)

            Button("Restore From Backup") {
                showBackupRestoreImporter = true
            }

            Text("Restore merges backup data and keeps your current entries when IDs conflict.")
                .font(.caption2)
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
        iCloudBackupEnabled = repository.iCloudBackupEnabled

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
            hasCompletedOnboarding: repository.settings.hasCompletedOnboarding,
            iCloudSyncEnabled: false,
            lastSyncAt: repository.settings.lastSyncAt,
            lastSyncError: repository.settings.lastSyncError
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

    private func exportData(for format: DataTransferFormat) -> Data {
        switch format {
        case .csv:
            return repository.exportCSV()
        case .json:
            return repository.exportJSON()
        case .sqlite:
            return repository.exportSQLite()
        case .appleHealthZip:
            return Data()
        }
    }

    private func importData(from url: URL, format: DataTransferFormat) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            switch format {
            case .csv:
                let data = try Data(contentsOf: url)
                repository.importCSV(from: data)
            case .json:
                let data = try Data(contentsOf: url)
                repository.importJSON(from: data)
            case .sqlite:
                repository.importSQLite(from: url)
            case .appleHealthZip:
                repository.importAppleHealthZIP(from: url)
            }
        } catch {
            repository.lastErrorMessage = "Unable to read \(format.label): \(error.localizedDescription)"
        }
    }
}

private enum DataTransferFormat: String, CaseIterable, Identifiable {
    case csv
    case json
    case sqlite
    case appleHealthZip

    static var importFormats: [DataTransferFormat] {
        [.csv, .json, .sqlite, .appleHealthZip]
    }

    static var exportFormats: [DataTransferFormat] {
        [.csv, .json, .sqlite]
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .csv:
            return "CSV"
        case .json:
            return "JSON"
        case .sqlite:
            return "SQLite"
        case .appleHealthZip:
            return "Apple Health ZIP"
        }
    }

    var allowedImportTypes: [UTType] {
        switch self {
        case .csv:
            return [.commaSeparatedText, .text]
        case .json:
            return [.json]
        case .sqlite:
            return [.sqliteDatabase, .sqliteDBFile, .sqlite3DBFile]
        case .appleHealthZip:
            return [.zip]
        }
    }

    var exportContentType: UTType {
        switch self {
        case .csv:
            return .commaSeparatedText
        case .json:
            return .json
        case .sqlite:
            return .sqliteDatabase
        case .appleHealthZip:
            return .data
        }
    }

    var defaultExportFilename: String {
        switch self {
        case .csv:
            return "weighin-export"
        case .json:
            return "weighin-export"
        case .sqlite:
            return "weighin-backup"
        case .appleHealthZip:
            return "weighin-export"
        }
    }
}

private extension UTType {
    static var sqliteDatabase: UTType {
        UTType(filenameExtension: "sqlite") ?? .data
    }

    static var sqliteDBFile: UTType {
        UTType(filenameExtension: "db") ?? .data
    }

    static var sqlite3DBFile: UTType {
        UTType(filenameExtension: "sqlite3") ?? .data
    }
}

private struct BinaryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .commaSeparatedText, .json, .sqliteDatabase] }

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

private struct BackupFolderPicker: UIViewControllerRepresentable {
    let onFolderPicked: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFolderPicked: onFolderPicked)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        controller.delegate = context.coordinator
        controller.allowsMultipleSelection = false
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFolderPicked: (URL) -> Void

        init(onFolderPicked: @escaping (URL) -> Void) {
            self.onFolderPicked = onFolderPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onFolderPicked(url)
        }
    }
}
