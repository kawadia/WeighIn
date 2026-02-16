import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var repository: AppRepository
    @State private var showingOnboarding = false

    var body: some View {
        TabView {
            LogView()
                .tabItem {
                    Label("Log", systemImage: "plus.circle.fill")
                }

            ChartsView()
                .tabItem {
                    Label("AI Analysis", systemImage: "chart.xyaxis.line")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .tint(AppTheme.accent)
        .preferredColorScheme(.dark)
        .onAppear {
            repository.loadAll()
            showingOnboarding = !repository.settings.hasCompletedOnboarding
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingSheet(
                settings: repository.settings,
                profile: repository.profile
            ) { updatedSettings, updatedProfile in
                repository.completeOnboarding(with: updatedSettings, profile: updatedProfile)
                showingOnboarding = false
            }
            .interactiveDismissDisabled(true)
        }
        .alert("Error", isPresented: Binding(
            get: { repository.lastErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    repository.lastErrorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(repository.lastErrorMessage ?? "")
        }
    }
}

extension View {
    func appScreenBackground() -> some View {
        background(AppTheme.background.ignoresSafeArea())
    }
}

private struct OnboardingSheet: View {
    let settings: AppSettings
    let profile: UserProfile
    let onComplete: (AppSettings, UserProfile) -> Void

    @State private var defaultUnit: WeightUnit
    @State private var reminderEnabled: Bool
    @State private var reminderTime: Date

    @State private var includeBirthday: Bool
    @State private var birthday: Date
    @State private var gender: Gender
    @State private var heightFeet: String
    @State private var heightInches: String

    init(settings: AppSettings, profile: UserProfile, onComplete: @escaping (AppSettings, UserProfile) -> Void) {
        self.settings = settings
        self.profile = profile
        self.onComplete = onComplete

        _defaultUnit = State(initialValue: settings.defaultUnit)
        _reminderEnabled = State(initialValue: settings.reminderEnabled)
        _reminderTime = State(initialValue: Calendar.current.date(from: DateComponents(
            hour: settings.reminderHour,
            minute: settings.reminderMinute
        )) ?? Calendar.current.date(from: DateComponents(hour: 7, minute: 0)) ?? Date())

        _includeBirthday = State(initialValue: profile.birthday != nil)
        _birthday = State(initialValue: profile.birthday ?? Date())
        _gender = State(initialValue: profile.gender)

        if let heightCm = profile.heightCentimeters {
            let totalInches = Int(round(heightCm / 2.54))
            _heightFeet = State(initialValue: String(totalInches / 12))
            _heightInches = State(initialValue: String(totalInches % 12))
        } else {
            _heightFeet = State(initialValue: "")
            _heightInches = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Welcome to Weight & Reflect") {
                    Text("Quick setup before your first log.")
                        .foregroundStyle(AppTheme.textSecondary)
                }

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

                Section("Profile") {
                    Toggle("Include birthday", isOn: $includeBirthday)
                    if includeBirthday {
                        DatePicker("Birthday", selection: $birthday, displayedComponents: .date)
                    }

                    Picker("Gender", selection: $gender) {
                        ForEach(Gender.allCases, id: \.self) { value in
                            Text(value.label).tag(value)
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
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle("Get Started")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        complete()
                    }
                }
            }
        }
    }

    private func complete() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        let updatedSettings = AppSettings(
            defaultUnit: defaultUnit,
            reminderEnabled: reminderEnabled,
            reminderHour: parts.hour ?? 7,
            reminderMinute: parts.minute ?? 0,
            hasCompletedOnboarding: true
        )

        let feet = Int(heightFeet) ?? 0
        let inches = Int(heightInches) ?? 0
        let heightCentimeters: Double?
        if feet == 0 && inches == 0 {
            heightCentimeters = nil
        } else {
            heightCentimeters = Double((feet * 12) + inches) * 2.54
        }

        let updatedProfile = UserProfile(
            birthday: includeBirthday ? birthday : nil,
            gender: gender,
            heightCentimeters: heightCentimeters,
            avatarPath: profile.avatarPath
        )

        onComplete(updatedSettings, updatedProfile)
    }
}
