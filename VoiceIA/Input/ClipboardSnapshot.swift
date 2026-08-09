import AppKit
import Foundation

/// Snapshot do conteúdo atual do clipboard, para restaurar após o paste.
struct ClipboardSnapshot {
    private let items: [NSPasteboardItem]

    /// Captura uma cópia profunda dos itens atuais do clipboard geral.
    static func capture(from pasteboard: NSPasteboard = .general) -> ClipboardSnapshot {
        let cloned: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            var wroteSomething = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    wroteSomething = true
                }
            }
            return wroteSomething ? copy : nil
        }
        return ClipboardSnapshot(items: cloned)
    }

    /// Restaura o snapshot no clipboard informado.
    func restore(into pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }
}
