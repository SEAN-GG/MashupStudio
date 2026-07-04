import SwiftUI

@main
struct MashupApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
