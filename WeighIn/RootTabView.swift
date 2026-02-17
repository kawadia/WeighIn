import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var repository: AppRepository
    @StateObject private var onboardingModel: OnboardingFlowViewModel

    private let loggingUseCase: any LoggingUseCase
    private let chartsUseCase: any ChartsUseCase
    private let settingsUseCase: any SettingsUseCase
    private let analysisUseCase: any AnalysisUseCase

    init(
        loggingUseCase: any LoggingUseCase,
        chartsUseCase: any ChartsUseCase,
        settingsUseCase: any SettingsUseCase,
        analysisUseCase: any AnalysisUseCase
    ) {
        self.loggingUseCase = loggingUseCase
        self.chartsUseCase = chartsUseCase
        self.settingsUseCase = settingsUseCase
        self.analysisUseCase = analysisUseCase
        _onboardingModel = StateObject(
            wrappedValue: OnboardingFlowViewModel(settingsUseCase: settingsUseCase)
        )
    }

    var body: some View {
        TabView {
            LogView(useCase: loggingUseCase)
                .tabItem {
                    Label("Log", systemImage: "plus.circle.fill")
                }

            ChartsView(useCase: chartsUseCase)
                .tabItem {
                    Label("Trends", systemImage: "chart.line.uptrend.xyaxis")
                }

            AIAnalysisView(useCase: analysisUseCase)
                .tabItem {
                    Label("AI Analysis", systemImage: "sparkles")
                }

            SettingsView(useCase: settingsUseCase)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .tint(AppTheme.accent)
        .preferredColorScheme(.dark)
        .onAppear {
            repository.loadAll()
            onboardingModel.refreshVisibility()
        }
        .sheet(isPresented: $onboardingModel.showingOnboarding) {
            OnboardingSheet(
                settings: settingsUseCase.settings,
                profile: settingsUseCase.profile
            ) { updatedSettings, updatedProfile in
                onboardingModel.completeOnboarding(
                    updatedSettings: updatedSettings,
                    updatedProfile: updatedProfile
                )
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
