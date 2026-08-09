import AppKit
import OSLog
import SwiftUI

/// Motivo pelo qual a ditagem não entrou sozinha no aplicativo.
enum InsertionRescueReason {
    /// Não havia nenhum campo de texto para receber o texto.
    case noFocusedField
    /// Havia um alvo, mas o aplicativo recusou a escrita.
    case insertionRefused

    var title: String {
        switch self {
        case .noFocusedField:
            return "Sem campo em foco"
        case .insertionRefused:
            return "Não deu para inserir"
        }
    }

    var subtitle: String {
        "A ditagem está aqui — nada foi copiado ainda"
    }

    var explanation: String {
        switch self {
        case .noFocusedField:
            return "Não havia nenhum campo de texto em foco para receber o que você ditou. Sua área de transferência foi preservada; use “Copiar” se quiser colar em algum lugar."
        case .insertionRefused:
            return "O aplicativo em foco não aceitou o texto ditado. Sua área de transferência foi preservada; use “Copiar” se quiser colar manualmente."
        }
    }

    /// Texto curto exibido no menu/HUD.
    var statusMessage: String {
        switch self {
        case .noFocusedField:
            return "Sem campo em foco: a ditagem ficou disponível no diálogo."
        case .insertionRefused:
            return "O app recusou a inserção: a ditagem ficou disponível no diálogo."
        }
    }
}

/// Diálogo persistente quando a ditagem não pôde ser inserida.
///
/// A área de transferência **não** é tocada ao abrir: só copiamos se o usuário
/// clicar em "Copiar", para não descartar o que ele já tinha copiado.
@MainActor
final class ClipboardFallbackDialogController {
    private var window: NSWindow?
    private let logger = Logger(subsystem: "dev.arley.santana.VoiceIA", category: "dialog")

    /// Altura enxuta: cabeçalho + texto + preview + botões, sem espaço morto.
    private static let contentSize = NSSize(width: 430, height: 248)

    /// Mostra o aviso. Só fecha quando o usuário confirma.
    func present(transcribedText preview: String, reason: InsertionRescueReason) {
        if let window, window.isVisible {
            logger.notice("Diálogo já visível; trazendo para frente.")
            bringToFront(window)
            return
        }

        window?.close()
        window = nil

        let built = makeWindow(preview: preview, reason: reason)
        window = built
        bringToFront(built)

        // Se por algum motivo a janela não subiu, cai para o alerta nativo.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            guard let window = self.window, window.isVisible else {
                self.logger.error("Janela do diálogo não ficou visível; usando NSAlert.")
                self.presentNativeAlert(preview: preview, reason: reason)
                return
            }
            self.logger.notice("Diálogo de resgate visível (\(reason.title, privacy: .public)).")
        }
    }

    private func makeWindow(preview: String, reason: InsertionRescueReason) -> NSWindow {
        let root = ClipboardFallbackDialogView(
            preview: preview,
            reason: reason,
            onCopy: {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(preview, forType: .string)
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = NSRect(origin: .zero, size: Self.contentSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "VoiceIA"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.contentSize)
        window.center()
        window.delegate = WindowCloseBridge.shared

        WindowCloseBridge.shared.onClose = { [weak self] in
            self?.handleClosed()
        }

        return window
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Último recurso: alerta nativo, que sempre aparece.
    private func presentNativeAlert(preview: String, reason: InsertionRescueReason) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = reason.title
        alert.informativeText = """
        \(reason.explanation)

        \(preview)
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copiar")
        alert.addButton(withTitle: "Entendi")

        if alert.runModal() == .alertFirstButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(preview, forType: .string)
        }

        handleClosed()
    }

    private func dismiss() {
        window?.close()
    }

    private func handleClosed() {
        window = nil
        WindowCloseBridge.shared.onClose = nil

        let hasOtherWindows = NSApp.windows.contains { candidate in
            candidate.isVisible
                && candidate.canBecomeKey
                && candidate.frame.width > 80
        }
        if !hasOtherWindows {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Ponte de fechamento da janela (evita retain cycle no controller).
private final class WindowCloseBridge: NSObject, NSWindowDelegate {
    static let shared = WindowCloseBridge()
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// Conteúdo visual do diálogo de resgate da ditagem.
private struct ClipboardFallbackDialogView: View {
    let preview: String
    let reason: InsertionRescueReason
    let onCopy: () -> Void
    let onDismiss: () -> Void

    @State private var didCopyFeedback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SettingsTheme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(reason.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(reason.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            Text(reason.explanation)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.06))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: SettingsTheme.hairline)
                    }
            }

            HStack(spacing: 10) {
                Button {
                    onCopy()
                    didCopyFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        didCopyFeedback = false
                    }
                } label: {
                    Label(didCopyFeedback ? "Copiado" : "Copiar", systemImage: didCopyFeedback ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DialogHalfButtonStyle(emphasized: false))

                Button("Entendi") {
                    onDismiss()
                }
                .buttonStyle(DialogHalfButtonStyle(emphasized: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430, height: 248, alignment: .topLeading)
        .background(SettingsBackground())
        .preferredColorScheme(.dark)
    }
}

/// Botão de metade da largura do diálogo (50% / 50%).
private struct DialogHalfButtonStyle: ButtonStyle {
    var emphasized: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                if emphasized {
                    Capsule().fill(SettingsTheme.accent.opacity(0.95))
                } else {
                    Capsule().fill(.white.opacity(configuration.isPressed ? 0.14 : 0.08))
                }
            }
            .overlay {
                Capsule().strokeBorder(.white.opacity(emphasized ? 0.22 : 0.16), lineWidth: SettingsTheme.hairline)
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
