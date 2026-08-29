import SwiftUI

@main
struct LookoutApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.servers.isEmpty {
                ServerSetupView()
            } else {
                MainTabView()
                    .task(id: model.activeServer?.id) { await model.bootstrap() }
                    .overlay {
                        if model.needsLogin {
                            LoginView()
                        }
                    }
                    .overlay {
                        if let challenge = model.certChallenge {
                            CertTrustView(challenge: challenge)
                        }
                    }
            }
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            LiveView()
                .tabItem { Label("Live", systemImage: "video.fill") }
                .tag(AppModel.Tab.live)
            DetectionsView()
                .tabItem { Label("Detections", systemImage: "rectangle.dashed.badge.record") }
                .tag(AppModel.Tab.detections)
            ExportsView()
                .tabItem { Label("Exports", systemImage: "square.and.arrow.down") }
                .tag(AppModel.Tab.exports)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppModel.Tab.settings)
        }
    }
}
