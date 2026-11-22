import SwiftUI
import StudioCore

@main
struct ArtelicoApp: App {
    init() {
        // Only the models in Artelico's model repository (artelico-models.json, written by
        // native/tools/package_hf.py); the Hailo-only ones stay in Hailo Studio.
        if let url = Bundle.main.url(forResource: "artelico-models", withExtension: "json"),
           let data = try? Data(contentsOf: url), let names = try? JSONDecoder().decode([String].self, from: data) {
            ModelCatalog.only = Set(names)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                #if targetEnvironment(macCatalyst)
                .onAppear(perform: Self.styleMacWindows)
                #endif
        }
    }

    #if targetEnvironment(macCatalyst)
    /// On the Mac the window title bar repeats "Artelico", which the sidebar already shows next to
    /// the logo. Hide it so the sidebar and the content start at the top of the window, and keep the
    /// window large enough for the two-column layout.
    static func styleMacWindows() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.titlebar?.titleVisibility = .hidden
            scene.titlebar?.toolbar = nil
            scene.sizeRestrictions?.minimumSize = CGSize(width: 980, height: 680)
        }
    }
    #endif
}
