import SwiftUI

@main
struct VIGBTApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.theme.colorScheme) // nil = match system (SPEC §11)
        }
    }
}
