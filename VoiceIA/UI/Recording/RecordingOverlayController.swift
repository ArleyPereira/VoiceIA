import AppKit
import SwiftUI

/// Controla o painel flutuante de feedback sem roubar o foco do app ativo.
/// Posição fixa (centro inferior). Recebe cliques só para pause/stop.
@MainActor
final class RecordingOverlayController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<RecordingOverlay>?
    private var appState: AppState?

    private let contentSize = NSSize(width: 300, height: 52)

    func sync(with appState: AppState) {
        self.appState = appState

        let style = RecordingHUDStyle(rawValue: appState.settings.recordingHUDStyle) ?? .moderno
        guard style.showsFloatingBar else {
            hide()
            return
        }

        switch appState.recordingState {
        case .recording, .paused, .error:
            show(using: appState)
        case .idle, .transcribing, .inserting, .success:
            hide()
        }
    }

    private func show(using appState: AppState) {
        if panel == nil {
            let built = makePanel(appState: appState)
            panel = built.panel
            hostingView = built.hosting
        } else if let hostingView {
            hostingView.rootView = RecordingOverlay(appState: appState)
        }

        guard let panel else { return }
        panel.setContentSize(contentSize)
        applyCapsuleMask(to: panel)
        // Precisa de mouse para pause/stop; não ativa o app.
        panel.ignoresMouseEvents = false
        placeFixed(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(appState: AppState) -> (panel: NSPanel, hosting: NSHostingView<RecordingOverlay>) {
        let hostingView = NSHostingView(rootView: RecordingOverlay(appState: appState))
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Sem sombra do sistema: ela aparece como borda preta fora da cápsula.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        applyCapsuleMask(to: panel)

        return (panel, hostingView)
    }

    private func applyCapsuleMask(to panel: NSPanel) {
        guard let content = panel.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.layer?.cornerRadius = contentSize.height / 2
        content.layer?.masksToBounds = true
        content.layer?.isOpaque = false
    }

    private func placeFixed(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - contentSize.width / 2
        let y = visible.minY + 36
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
