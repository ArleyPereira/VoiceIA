import SwiftUI

@main
struct VoiceIAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Label("VoiceIA", systemImage: "waveform")
                .labelStyle(.iconOnly)
                .help(helpText)
        }
    }

    private var helpText: String {
        let hotkey = appState.settings.dictationHotkey
        switch appState.recordingState {
        case .recording:
            return "VoiceIA — Ouvindo… solte \(hotkey.displayName)"
        case .success:
            return "VoiceIA — Concluído"
        case .error:
            return "VoiceIA — Erro"
        default:
            return "VoiceIA — \(hotkey.holdInstruction)"
        }
    }
}
