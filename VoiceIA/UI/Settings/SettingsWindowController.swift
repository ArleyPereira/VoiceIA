import AppKit
import SwiftUI

/// Janela de configurações via AppKit — mais confiável que `Settings` scene em Menu Bar apps.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private weak var settings: AppSettings?
    private var viewModel: SettingsViewModel?
    private var systemAppearanceObserver: NSObjectProtocol?

    /// Tamanho mínimo (= padrão ao abrir). O usuário só pode aumentar.
    private static let defaultContentSize = NSSize(width: 860, height: 620)

    /// Mostra (ou reusa) a janela de configurações.
    ///
    /// - Parameter onTranscriptionPolicyChanged: chamado quando modo teste,
    ///   backend local, modelo ou GPU mudam — para liberar o Whisper da memória.
    func show(settings: AppSettings, onTranscriptionPolicyChanged: @escaping () -> Void = {}) {
        self.settings = settings
        settings.refreshAPIKeyStatus()

        let applyTheme: () -> Void = { [weak self] in
            self?.applyAppearanceTheme()
        }

        if let viewModel {
            viewModel.onTranscriptionPolicyChanged = onTranscriptionPolicyChanged
            viewModel.onAppearanceThemeChanged = applyTheme
        } else {
            let viewModel = SettingsViewModel(
                settings: settings,
                onTranscriptionPolicyChanged: onTranscriptionPolicyChanged,
                onAppearanceThemeChanged: applyTheme
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
            window.backgroundColor = .clear
            window.setContentSize(Self.defaultContentSize)
            window.minSize = window.frameRect(
                forContentRect: NSRect(origin: .zero, size: Self.defaultContentSize)
            ).size
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = WindowCloseObserver.shared
            WindowCloseObserver.shared.onClose = { [weak self] in
                self?.handleClosed()
            }
            self.window = window
            startObservingSystemAppearance()
        }

        enforceMinimumWindowSize()
        applyAppearanceTheme()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// Garante o tamanho padrão ao abrir e impede encolher abaixo dele.
    private func enforceMinimumWindowSize() {
        guard let window else { return }
        window.setContentSize(Self.defaultContentSize)
        window.minSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: Self.defaultContentSize)
        ).size
    }

    /// Aplica Sistema / Claro / Escuro na janela AppKit.
    private func applyAppearanceTheme() {
        let theme = AppAppearanceTheme(rawValue: settings?.appearanceTheme ?? "") ?? .system
        // Aparência concreta: `nil` após forçar claro/escuro não reaplica o
        // tema do sistema até a janela perder o foco.
        window?.appearance = theme.resolvedNSAppearance()
        window?.contentView?.appearance = nil
        window?.displayIfNeeded()
    }

    private func startObservingSystemAppearance() {
        guard systemAppearanceObserver == nil else { return }
        systemAppearanceObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.viewModel?.handleSystemAppearanceChanged()
            }
        }
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

    deinit {
        if let systemAppearanceObserver {
            DistributedNotificationCenter.default.removeObserver(systemAppearanceObserver)
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
