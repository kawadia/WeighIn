import SwiftUI

@main
struct WeighInApp: App {
    @StateObject private var repository = AppRepository()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(repository)
        }
    }
}
