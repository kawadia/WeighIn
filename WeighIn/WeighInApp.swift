import SwiftUI

@main
struct WeighInApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var repository = AppRepository(cloudKitSyncFeatureEnabled: false)

    var body: some Scene {
        WindowGroup {
            RootTabView(
                loggingUseCase: repository,
                chartsUseCase: repository,
                settingsUseCase: repository,
                analysisUseCase: repository
            )
                .environmentObject(repository)
                .onAppear {
                    repository.triggerDailyBackupIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    repository.triggerDailyBackupIfNeeded()
                }
        }
    }
}
