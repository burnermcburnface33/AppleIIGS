import SwiftUI

struct MainView: View {
    @EnvironmentObject private var emu: EmulatorController
    @State private var showDiskManager = false
    @State private var showSaveStates  = false
    @State private var showSettings    = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    TopToolbar(showDisks: $showDiskManager,
                               showSaveStates: $showSaveStates,
                               showSettings: $showSettings)
                        .frame(height: 44)
                        .background(Color(white: 0.07))

                    EmulatorScreenView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)

                    InputArea()
                        .frame(height: inputAreaHeight(proxy: proxy))
                        .background(Color(white: 0.04))
                }
            }
        }
        .sheet(isPresented: $showDiskManager) {
            DiskManagerView().environmentObject(emu)
        }
        .sheet(isPresented: $showSaveStates) {
            SaveStatesView().environmentObject(emu)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(emu)
        }
        .task {
            emu.bootstrap()
        }
    }

    private func inputAreaHeight(proxy: GeometryProxy) -> CGFloat {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        switch emu.inputMode {
        case .keyboard:
            // Just enough to host the responder; the inputAccessoryView floats
            // at the bottom of the screen on its own.
            return 1
        case .joystick:
            return proxy.size.height * (isPad ? 0.30 : 0.40)
        case .touch:
            return 0
        }
    }
}

struct TopToolbar: View {
    @EnvironmentObject private var emu: EmulatorController
    @Binding var showDisks: Bool
    @Binding var showSaveStates: Bool
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 14) {
            Button { emu.pauseOrResume() } label: {
                Image(systemName: emu.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
            }
            Button { emu.reset() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 16, weight: .semibold))
            }

            Spacer()

            Picker("Mode", selection: $emu.inputMode) {
                ForEach(InputMode.allCases) { mode in
                    Image(systemName: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            Spacer()

            Button { showDisks.toggle() } label: {
                Image(systemName: "opticaldiscdrive")
                    .font(.system(size: 16, weight: .semibold))
            }
            Button { showSaveStates.toggle() } label: {
                Image(systemName: "tray.full")
                    .font(.system(size: 16, weight: .semibold))
            }
            Button { showSettings.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
            }
        }
        .padding(.horizontal, 12)
        .foregroundStyle(.white)
    }
}

struct InputArea: View {
    @EnvironmentObject private var emu: EmulatorController

    var body: some View {
        Group {
            switch emu.inputMode {
            case .keyboard: KeyboardInputArea()
            case .joystick: JoystickOverlay()
            case .touch:    Color.clear
            }
        }
    }
}
