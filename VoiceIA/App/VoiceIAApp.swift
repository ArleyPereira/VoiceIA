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
            MenuBarWaveformIconView()
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
        case .awaitingManualInsert:
            return "VoiceIA — Arraste ou copie o texto"
        default:
            return "VoiceIA — \(hotkey.holdInstruction)"
        }
    }
}
