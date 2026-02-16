import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var repository: AppRepository

    var body: some View {
        TabView {
            LogView()
                .tabItem {
                    Label("Log", systemImage: "plus.circle.fill")
                }

            ChartsView()
                .tabItem {
                    Label("Charts", systemImage: "chart.xyaxis.line")
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
