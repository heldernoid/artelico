import SwiftUI

@main
struct UGenProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                #if targetEnvironment(macCatalyst)
                .onAppear(perform: Self.styleMacWindows)
                #endif
        }
    }

    #if targetEnvironment(macCatalyst)
    /// On the Mac the window title bar repeats "Hailo Studio", which the sidebar already shows next to
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
