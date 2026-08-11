import SwiftUI

@main
struct DotMatrixApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryView()
                // The emulator is drawn on black and the controls are tuned for
                // it; forcing dark keeps the chrome from fighting the screen.
                .preferredColorScheme(.dark)
        }
    }
}
