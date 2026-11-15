import SwiftUI

@main
struct VIGBTApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark) // high contrast: white/yellow on black
        }
    }
}
