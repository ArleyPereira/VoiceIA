import Carbon
import Foundation

/// Configuração central do atalho global de ditado.
enum HotkeyConfiguration {
    /// Código da tecla Tab.
    static let keyCode = UInt32(kVK_Tab)

    /// Modificador Shift.
    static let modifiers = UInt32(shiftKey)

    /// Texto exibido na interface (⇧ Tab).
    static let displayName = "⇧ Tab"

    /// Instrução curta de uso.
    static let holdInstruction = "⇧ Shift + Tab para gravar · pause/continua no HUD · ⇧ Shift + Tab de novo para enviar"
}
