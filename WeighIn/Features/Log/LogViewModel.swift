import Foundation
import AVFoundation
import Speech
import Combine

@MainActor
final class LogViewModel: ObservableObject {
    private struct EntryDraft: Codable {
        let weightInput: String
        let noteInput: String
        let entryTimestamp: Date
    }

    private enum Constants {
        static let draftDefaultsKey = "log_entry_draft_v1"
    }

    @Published var weightInput: String = ""
    @Published var noteInput: String = ""
    @Published var entryTimestamp: Date = Date()
    @Published var lastSaveMessage = ""
    @Published var isVoiceRecording = false
    @Published var liveVoiceTranscript = ""

    private var lastSavedNoteID: String?
    private var lastSavedNormalizedNoteText = ""
    private var isVoicePressActive = false
    private var isVoiceStartInFlight = false
    private let shouldPersistDraft: Bool
    private var cancellables: Set<AnyCancellable> = []
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    convenience init() {
        self.init(shouldPersistDraft: LogViewModel.defaultShouldPersistDraft)
    }

    init(shouldPersistDraft: Bool) {
        self.shouldPersistDraft = shouldPersistDraft
        if shouldPersistDraft {
            restoreDraftIfAvailable()
            setupDraftAutosave()
        }
    }

    nonisolated static var defaultShouldPersistDraft: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    var parsedWeight: Double? {
        Double(weightInput)
    }

    var canSaveNote: Bool {
        let normalized = noteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && normalized != lastSavedNormalizedNoteText
    }

    func handleKey(_ key: String) {
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

    func saveCurrentWeight(using repository: AppRepository) {
        guard let weight = parsedWeight, weight > 0 else { return }
        repository.addWeightLog(
            weight: weight,
            timestamp: entryTimestamp,
            noteText: nil,
            source: .manual
        )
        weightInput = ""
        entryTimestamp = Date()
    }

    func saveUnifiedEntry(using repository: AppRepository) {
        guard let weight = parsedWeight, weight > 0 else {
            lastSaveMessage = "Enter a valid weight to save"
            return
        }

        let normalizedNote = noteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        repository.addWeightLog(
            weight: weight,
            timestamp: entryTimestamp,
            noteText: normalizedNote.isEmpty ? nil : normalizedNote,
            source: .manual
        )

        guard repository.lastErrorMessage == nil else { return }

        weightInput = ""
        noteInput = ""
        entryTimestamp = Date()
        clearDraft()

        if normalizedNote.isEmpty {
            lastSaveMessage = "Saved. Reflection is optional but improves analysis."
        } else {
            lastSaveMessage = "Saved entry \(DateFormatting.shortDateTime.string(from: Date()))"
        }
    }

    func saveNoteNow(using repository: AppRepository) {
        let normalized = noteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        guard normalized != lastSavedNormalizedNoteText else {
            lastSaveMessage = "No changes to save"
            return
        }

        lastSavedNoteID = repository.upsertStandaloneNote(
            id: lastSavedNoteID,
            text: normalized,
            timestamp: Date()
        )

        if lastSavedNoteID != nil {
            lastSavedNormalizedNoteText = normalized
            lastSaveMessage = "Saved \(DateFormatting.shortDateTime.string(from: Date()))"
        }
    }

    func beginVoiceCapturePress() {
        isVoicePressActive = true
        guard !isVoiceRecording, !isVoiceStartInFlight else { return }

        isVoiceStartInFlight = true
        Task {
            await startVoiceRecording()
        }
    }

    func endVoiceCapturePress() {
        isVoicePressActive = false
        guard isVoiceRecording else { return }
        stopVoiceRecording(appendTranscript: true)
    }

    func stopVoiceRecordingIfNeeded() {
        isVoicePressActive = false
        guard isVoiceRecording else { return }
        stopVoiceRecording(appendTranscript: false)
    }

    private func startVoiceRecording() async {
        defer {
            isVoiceStartInFlight = false
        }

        guard isVoicePressActive else { return }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            lastSaveMessage = "Voice transcription unavailable right now"
            return
        }

        let speechAuthorized = await requestSpeechAuthorization() == .authorized
        guard isVoicePressActive else { return }
        guard speechAuthorized else {
            lastSaveMessage = "Allow Speech Recognition in Settings to use voice notes"
            return
        }

        let micAuthorized = await requestMicrophonePermission()
        guard isVoicePressActive else { return }
        guard micAuthorized else {
            lastSaveMessage = "Allow Microphone access in Settings to use voice notes"
            return
        }

        do {
            try configureAudioSession()
            try startRecognition(with: speechRecognizer)
            isVoiceRecording = true
            liveVoiceTranscript = ""
            lastSaveMessage = "Listening… release to stop"
        } catch {
            stopVoiceRecording(appendTranscript: false)
            lastSaveMessage = "Could not start voice note: \(error.localizedDescription)"
        }
    }

    private func stopVoiceRecording(appendTranscript: Bool) {
        isVoicePressActive = false

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        if appendTranscript {
            let text = liveVoiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                lastSaveMessage = "No speech detected"
            } else {
                appendToNote(text)
                lastSaveMessage = "Voice note added"
            }
        }

        liveVoiceTranscript = ""
        isVoiceRecording = false
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startRecognition(with recognizer: SFSpeechRecognizer) throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let result {
                    self.liveVoiceTranscript = result.bestTranscription.formattedString
                }

                if let error {
                    self.stopVoiceRecording(appendTranscript: false)
                    self.lastSaveMessage = "Voice note stopped: \(error.localizedDescription)"
                    return
                }
            }
        }
    }

    private func appendToNote(_ addition: String) {
        let existing = noteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.isEmpty {
            noteInput = addition
            return
        }

        if noteInput.hasSuffix("\n") {
            noteInput += addition
        } else {
            noteInput += "\n\(addition)"
        }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func setupDraftAutosave() {
        Publishers.CombineLatest3($weightInput, $noteInput, $entryTimestamp)
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] weightInput, noteInput, entryTimestamp in
                self?.persistDraft(
                    weightInput: weightInput,
                    noteInput: noteInput,
                    entryTimestamp: entryTimestamp
                )
            }
            .store(in: &cancellables)
    }

    private func persistDraft(weightInput: String, noteInput: String, entryTimestamp: Date) {
        guard shouldPersistDraft else { return }

        let trimmedNote = noteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !weightInput.isEmpty || !trimmedNote.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Constants.draftDefaultsKey)
            return
        }

        let draft = EntryDraft(
            weightInput: weightInput,
            noteInput: noteInput,
            entryTimestamp: entryTimestamp
        )
        guard let data = try? JSONEncoder().encode(draft) else { return }
        UserDefaults.standard.set(data, forKey: Constants.draftDefaultsKey)
    }

    private func restoreDraftIfAvailable() {
        guard shouldPersistDraft else { return }
        guard let data = UserDefaults.standard.data(forKey: Constants.draftDefaultsKey),
              let draft = try? JSONDecoder().decode(EntryDraft.self, from: data) else {
            return
        }

        let trimmedNote = draft.noteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.weightInput.isEmpty || !trimmedNote.isEmpty else { return }

        weightInput = draft.weightInput
        noteInput = draft.noteInput
        entryTimestamp = draft.entryTimestamp
        lastSaveMessage = "Draft restored"
    }

    private func clearDraft() {
        guard shouldPersistDraft else { return }
        UserDefaults.standard.removeObject(forKey: Constants.draftDefaultsKey)
    }
}
