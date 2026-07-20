import SwiftUI

@main
struct AppleIIGSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentRoot()
        }
    }
}

private struct ContentRoot: View {
    @State private var didStart = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !didStart {
                Text("Booting Apple //GS…")
                    .foregroundStyle(.white)
                    .onAppear {
                        // Kick off emulator on the main thread
                        _ = EmulatorController.shared
                        didStart = true
                    }
            } else {
                MainView()
                    .environmentObject(EmulatorController.shared)
                    .preferredColorScheme(.dark)
                    .onOpenURL { url in
                        EmulatorController.shared.importDiskImage(from: url)
                    }
            }
        }
    }
}
