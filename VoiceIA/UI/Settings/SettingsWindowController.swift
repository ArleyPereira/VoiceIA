import AppKit
import SwiftUI

/// Janela de configurações via AppKit — mais confiável que `Settings` scene em Menu Bar apps.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private weak var settings: AppSettings?
    private var viewModel: SettingsViewModel?

    private static let contentSize = NSSize(width: 860, height: 580)

    /// Mostra (ou reusa) a janela de configurações.
    ///
    /// - Parameter onTranscriptionPolicyChanged: chamado quando modo teste,
    ///   backend local, modelo ou GPU mudam — para liberar o Whisper da memória.
    func show(settings: AppSettings, onTranscriptionPolicyChanged: @escaping () -> Void = {}) {
        self.settings = settings
        settings.refreshAPIKeyStatus()

        if let viewModel {
            viewModel.onTranscriptionPolicyChanged = onTranscriptionPolicyChanged
        } else {
            let viewModel = SettingsViewModel(
                settings: settings,
                onTranscriptionPolicyChanged: onTranscriptionPolicyChanged
            )
            self.viewModel = viewModel
            let root = SettingsView(viewModel: viewModel)
            let hosting = NSHostingController(rootView: root)

            let window = NSWindow(contentViewController: hosting)
            window.title = "Configurações — VoiceIA"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            // Barra de título some no fundo translúcido; o título fica na própria tela.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .clear
            window.setContentSize(Self.contentSize)
            window.minSize = NSSize(width: 780, height: 540)
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = WindowCloseObserver.shared
            WindowCloseObserver.shared.onClose = { [weak self] in
                self?.handleClosed()
            }
            self.window = window
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func handleClosed() {
        let hasOtherWindows = NSApp.windows.contains { candidate in
            candidate !== window
                && candidate.isVisible
                && candidate.canBecomeKey
                && candidate.frame.width > 80
        }
        if !hasOtherWindows {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Observa o fechamento da janela de configurações.
private final class WindowCloseObserver: NSObject, NSWindowDelegate {
    static let shared = WindowCloseObserver()
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
