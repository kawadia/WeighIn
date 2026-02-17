import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var repository: AppRepository
    private let useCase: any SettingsUseCase

    init(useCase: any SettingsUseCase) {
        self.useCase = useCase
    }

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
    @State private var showAppleHealthImportPicker = false
    @State private var iCloudBackupEnabled = false
    @State private var appleHealthImportMessage: String?
    @State private var showDeleteAllDataConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                preferencesSection
                dataSection
                backupSection
                legalSection
                dangerZoneSection
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle("Settings")
            .onAppear(perform: loadState)
            .onChange(of: defaultUnit) { _, _ in savePreferences() }
            .onChange(of: reminderEnabled) { _, _ in savePreferences() }
            .onChange(of: reminderTime) { _, _ in savePreferences() }
            .onChange(of: iCloudBackupEnabled) { _, newValue in
                useCase.setICloudBackupEnabled(newValue)
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
                    useCase.lastErrorMessage = "Unable to export \(selectedExportFormat.label): \(error.localizedDescription)"
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
                    useCase.setBackupFolder(folderURL)
                }
            }
            .sheet(isPresented: $showAppleHealthImportPicker) {
                AppleHealthImportPicker { selectedURL in
                    importData(from: selectedURL, format: .appleHealthZip)
                }
            }
            .confirmationDialog("Import Format", isPresented: $showImportFormatPicker, titleVisibility: .visible) {
                ForEach(DataTransferFormat.importFormats) { format in
                    Button(format.label) {
                        selectedImportFormat = format
                        if format == .appleHealthZip {
                            showAppleHealthImportPicker = true
                        } else {
                            showImporter = true
                        }
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
            .alert("Apple Health Import Complete", isPresented: Binding(
                get: { appleHealthImportMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        appleHealthImportMessage = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(appleHealthImportMessage ?? "")
            }
            .confirmationDialog("Delete all app data on this device?", isPresented: $showDeleteAllDataConfirmation, titleVisibility: .visible) {
                Button("Delete All Data", role: .destructive) {
                    useCase.deleteAllData()
                }
                Button("Cancel", role: .cancel) {}
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

    private var dangerZoneSection: some View {
        Section("Danger Zone") {
            Button("Delete All Data", role: .destructive) {
                showDeleteAllDataConfirmation = true
            }

            Text("This action cannot be undone.")
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
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

            if let folderName = useCase.backupFolderDisplayName() {
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
                useCase.triggerBackupNow()
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
        defaultUnit = useCase.settings.defaultUnit
        reminderEnabled = useCase.settings.reminderEnabled
        reminderTime = Calendar.current.date(from: DateComponents(
            hour: useCase.settings.reminderHour,
            minute: useCase.settings.reminderMinute
        )) ?? Date()
        iCloudBackupEnabled = repository.iCloudBackupEnabled

        birthday = useCase.profile.birthday
        gender = useCase.profile.gender
        avatarPath = useCase.profile.avatarPath

        if let heightCm = useCase.profile.heightCentimeters {
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
            hasCompletedOnboarding: useCase.settings.hasCompletedOnboarding,
            iCloudSyncEnabled: false,
            lastSyncAt: useCase.settings.lastSyncAt,
            lastSyncError: useCase.settings.lastSyncError
        )

        guard updated != useCase.settings else { return }
        useCase.updateSettings(updated)
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

        guard updated != useCase.profile else { return }
        useCase.updateProfile(updated)
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
            useCase.lastErrorMessage = "Could not save profile image: \(error.localizedDescription)"
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
            return useCase.exportCSV()
        case .json:
            return useCase.exportJSON()
        case .sqlite:
            return useCase.exportSQLite()
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
                useCase.importCSV(from: data)
            case .json:
                let data = try Data(contentsOf: url)
                useCase.importJSON(from: data)
            case .sqlite:
                useCase.importSQLite(from: url)
            case .appleHealthZip:
                if let summary = useCase.importAppleHealthZIP(from: url) {
                    appleHealthImportMessage = "Processed \(summary.processedRecords) records. Added \(summary.newRecords) new entries."
                }
            }
        } catch {
            useCase.lastErrorMessage = "Unable to read \(format.label): \(error.localizedDescription)"
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
            return "Apple Health Export"
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
            return [.zip, .folder]
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

private struct AppleHealthImportPicker: UIViewControllerRepresentable {
    let onSelection: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: [.zip, .folder],
            asCopy: false
        )
        controller.delegate = context.coordinator
        controller.allowsMultipleSelection = false
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelection: (URL) -> Void

        init(onSelection: @escaping (URL) -> Void) {
            self.onSelection = onSelection
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onSelection(url)
        }
    }
}
