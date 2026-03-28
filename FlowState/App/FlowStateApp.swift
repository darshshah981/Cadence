import SwiftUI

@main
struct FlowStateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra("FlowState", systemImage: appModel.menuBarSymbolName) {
            MenuContentView(appModel: appModel)
                .frame(width: 380)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appModel: appModel)
                .frame(width: 460, height: 460)
        }
    }
}
