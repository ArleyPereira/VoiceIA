import AppKit
import ApplicationServices
import Carbon
import Foundation
import OSLog

/// Estratégia usada na última inserção bem-sucedida (diagnóstico).
enum InsertionMethod: String {
    case accessibility = "Accessibility"
    case unicodeTyping = "digitação Unicode"
    case clipboardHID = "⌘V (HID)"
    case clipboardSession = "⌘V (sessão)"
    case clipboardSystemEvents = "⌘V (System Events)"
}

/// Insere texto no campo em foco de qualquer aplicativo.
///
/// Três caminhos, nesta ordem:
/// 1. Accessibility direto — apps nativos (Notas, TextEdit, Safari).
/// 2. Digitação Unicode sintética — Electron/Chromium (Cursor, VS Code, Chrome).
///    Entrega o texto como entrada de teclado, **sem encostar na área de
///    transferência** do usuário.
/// 3. Clipboard + ⌘V — último recurso; o conteúdo anterior é sempre restaurado.
///
/// A etapa 1 é sempre **verificada por releitura**: apps Electron respondem
/// `success` ao `AXUIElementSetAttributeValue` sem alterar o campo, e confiar
/// nesse retorno impedia os fallbacks de rodar.
final class DefaultTextInsertionService: TextInsertionService, @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.arley.santana.VoiceIA", category: "insertion")
    private let accessibilityService: any AccessibilityServiceProtocol
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Papéis em que a escrita direta via AX faz sentido tentar.
    private let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]

    /// Resultado da checagem por releitura do valor AX.
    private enum InsertionCheck {
        /// O valor do campo mudou como esperado.
        case confirmed
        /// O valor continua idêntico: a inserção não chegou ao campo.
        case rejected
        /// O campo não expõe valor legível; não dá para afirmar nada.
        case unknown
    }

    private(set) var lastMethod: InsertionMethod?

    init(accessibilityService: any AccessibilityServiceProtocol) {
        self.accessibilityService = accessibilityService
    }

    func insert(text: String) async throws {
        try await performInsertion(text: text, captured: nil)
    }

    func insert(text: String, into captured: FocusedElement) async throws {
        try await performInsertion(text: text, captured: captured)
    }

    // MARK: - Núcleo

    private func performInsertion(text: String, captured: FocusedElement?) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VoiceInputError.emptyTranscription
        }

        guard accessibilityService.isTrusted() else {
            logger.error("Sem confiança de Acessibilidade; inserção abortada.")
            throw VoiceInputError.accessibilityPermissionDenied
        }

        // O atalho é ⇧ Tab: se o Shift ainda estiver baixo, o ⌘V vira ⌘⇧V e a
        // digitação sai com caracteres errados.
        await waitForClearModifiers()

        // Depois de uma transcrição longa o app alvo pode ter perdido o
        // frontmost; reativar antes de reler o foco evita alvo fantasma.
        if let captured {
            try? await activateAndWait(pid: captured.processID)
        }

        let liveTarget = await resolveTargetWithRetry()
        let candidates = [captured, liveTarget].compactMap { $0 }

        // Exige um alvo genuinamente editável. Eventos de teclado/clipboard são
        // globais — não ficam restritos ao nó AX que escolhemos — então, sem
        // confirmação de que o alvo é mesmo um campo de texto, não dá para
        // confiar na verificação (ela checaria o nó errado) nem saber se já
        // inserimos em algum lugar. Melhor não tentar do que arriscar duplicar
        // a ditagem num campo invisível para a Acessibilidade.
        guard let target = candidates.compactMap({ resolveEditableTarget(from: $0) }).first else {
            let summary = candidates.map(\.summary).joined(separator: ", ")
            logger.notice("Sem campo editável em foco (candidatos: \(summary.isEmpty ? "nenhum" : summary, privacy: .public)).")
            throw VoiceInputError.noFocusedElement
        }

        logDiagnostics(target: target, captured: captured, live: liveTarget)

        if insertViaAccessibilityVerified(trimmed, into: target) {
            lastMethod = .accessibility
            logger.notice("Inserido via Accessibility em \(target.summary, privacy: .public)")
            return
        }

        // Caminho principal do Cursor/Electron: digitar sem mexer no clipboard.
        switch await insertViaUnicodeTyping(trimmed, target: target) {
        case .confirmed:
            lastMethod = .unicodeTyping
            logger.notice("Inserido via digitação Unicode (verificado).")
            return
        case .unknown:
            lastMethod = .unicodeTyping
            logger.notice("Digitação Unicode enviada; campo não expõe valor para verificar.")
            return
        case .rejected:
            logger.notice("Digitação Unicode não alterou o campo; tentando clipboard + ⌘V.")
        }

        try await insertViaClipboardPaste(trimmed, target: target)
    }

    private func logDiagnostics(target: FocusedElement, captured: FocusedElement?, live: FocusedElement?) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "desconhecido"
        logger.notice(
            """
            Alvo: \(target.summary, privacy: .public) pid=\(target.processID, privacy: .public) \
            editável=\(self.isEditable(target), privacy: .public) \
            frontmost=\(frontmost, privacy: .public) \
            capturado=\(captured?.summary ?? "nenhum", privacy: .public) \
            ao-vivo=\(live?.summary ?? "nenhum", privacy: .public)
            """
        )
    }

    /// Alvo aceitável para escrita AX: papel de texto conhecido ou atributo gravável.
    private func isEditable(_ target: FocusedElement) -> Bool {
        if let role = target.role, editableRoles.contains(role) {
            return true
        }
        return isAttributeSettable(target.axElement, kAXSelectedTextAttribute as CFString)
            || isAttributeSettable(target.axElement, kAXValueAttribute as CFString)
    }

    /// Se o elemento (ou um descendente focado) for editável, devolve esse alvo.
    private func resolveEditableTarget(from target: FocusedElement) -> FocusedElement? {
        if isEditable(target) {
            return target
        }

        // Electron: o foco sobe para janela/grupo; desce de novo até o UI focado.
        guard let nested = focusedDescendant(of: target.axElement) else { return nil }

        let refined = FocusedElement(
            axElement: nested,
            processID: target.processID,
            applicationName: target.applicationName,
            role: copyStringAttribute(nested, kAXRoleAttribute as CFString)
        )
        guard isEditable(refined) else { return nil }

        logger.notice("Foco refinado: \(refined.summary, privacy: .public)")
        return refined
    }

    private func focusedDescendant(of element: AXUIElement) -> AXUIElement? {
        let containerRoles: Set<String> = [
            kAXApplicationRole as String,
            kAXWindowRole as String,
            "AXGroup",
            "AXWebArea",
            "AXScrollArea"
        ]

        var current = element
        for _ in 0..<5 {
            let role = copyStringAttribute(current, kAXRoleAttribute as CFString)
            guard let role, containerRoles.contains(role) else { return current }

            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                current,
                kAXFocusedUIElementAttribute as CFString,
                &value
            )
            guard status == .success,
                  let value,
                  CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            current = (value as! AXUIElement)
        }
        return current
    }

    private func isAttributeSettable(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return status == .success && settable.boolValue
    }

    // MARK: - Descoberta do alvo

    /// Procura o foco atual, insistindo até achar um campo realmente editável.
    ///
    /// O Chromium leva alguns instantes para montar a árvore de acessibilidade
    /// depois que ela é solicitada; desistir na primeira resposta devolveria só
    /// a janela, perdendo o campo de texto.
    private func resolveTargetWithRetry() async -> FocusedElement? {
        var lastSeen: FocusedElement?

        for attempt in 0..<8 {
            if let target = try? accessibilityService.focusedElement(),
               target.processID != ownPID {
                if resolveEditableTarget(from: target) != nil {
                    return target
                }
                lastSeen = target
            }
            if attempt < 7 {
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        return lastSeen
    }

    private func waitForClearModifiers() async {
        let blocking: CGEventFlags = [.maskShift, .maskCommand, .maskAlternate, .maskControl]

        for _ in 0..<60 {
            if CGEventSource.flagsState(.hidSystemState).intersection(blocking).isEmpty {
                try? await Task.sleep(for: .milliseconds(50))
                return
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        logger.warning("Modificadores ainda pressionados; seguindo mesmo assim.")
    }

    // MARK: - Accessibility verificado

    private func insertViaAccessibilityVerified(_ text: String, into target: FocusedElement) -> Bool {
        let role = target.role ?? ""
        guard editableRoles.contains(role) else {
            logger.info("Papel \(role.isEmpty ? "desconhecido" : role, privacy: .public) não é campo editável nativo.")
            return false
        }

        let element = target.axElement
        let placeholder = axPlaceholder(of: element)
        let beforeRaw = copyStringAttribute(element, kAXValueAttribute as CFString)
        let before = strippingPlaceholder(from: beforeRaw, placeholder: placeholder)

        // Só selectedText. Reescrever kAXValueAttribute no Electron materializa o
        // placeholder ("Send follow-up") como texto real no contenteditable.
        if setAttribute(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef),
           didInsertSucceed(
            element,
            beforeRaw: beforeRaw,
            before: before,
            inserted: text,
            placeholder: placeholder
           ) {
            return true
        }

        return false
    }

    /// Placeholder AX (nativo) ou valor que o Electron expõe como se fosse conteúdo.
    private func axPlaceholder(of element: AXUIElement) -> String? {
        if let placeholder = copyStringAttribute(element, kAXPlaceholderValueAttribute as CFString),
           !placeholder.isEmpty {
            return placeholder
        }
        return nil
    }

    private func strippingPlaceholder(from raw: String?, placeholder: String?) -> String {
        guard var value = raw, !value.isEmpty else { return "" }
        guard let placeholder, !placeholder.isEmpty else { return value }

        if value == placeholder {
            return ""
        }
        // Cursor/Electron: muitas vezes o valor AX é "conteúdo real" + placeholder no fim.
        if value.hasSuffix(placeholder) {
            value.removeLast(placeholder.count)
            return value
        }
        if value.hasPrefix(placeholder) {
            value.removeFirst(placeholder.count)
            return value
        }
        return value
    }

    /// Confirma inserção real e rejeita se o placeholder do Electron ficou no valor.
    private func didInsertSucceed(
        _ element: AXUIElement,
        beforeRaw: String?,
        before: String,
        inserted: String,
        placeholder: String?
    ) -> Bool {
        let afterRaw = copyStringAttribute(element, kAXValueAttribute as CFString)
        let after = strippingPlaceholder(from: afterRaw, placeholder: placeholder)

        guard let afterRaw, after.contains(inserted), after != before else { return false }

        // Placeholder oficial ainda presente no valor cru.
        if let placeholder,
           !inserted.contains(placeholder),
           afterRaw.contains(placeholder) {
            logger.info("AX manteve o placeholder \"\(placeholder, privacy: .public)\"; tratando como falha.")
            return false
        }

        // Sem atributo placeholder: valor curto anterior preservado no after
        // (ex.: "Send follow-up") → era placeholder do Electron.
        if let beforeRaw,
           !beforeRaw.isEmpty,
           beforeRaw.count <= 48,
           !beforeRaw.contains("\n"),
           !inserted.contains(beforeRaw),
           afterRaw.contains(beforeRaw),
           afterRaw != inserted {
            logger.info("AX preservou rótulo curto pré-existente; tratando como placeholder.")
            return false
        }

        return true
    }

    // MARK: - Digitação Unicode (sem clipboard)

    /// Envia o texto como eventos de teclado com payload Unicode.
    ///
    /// `keyboardSetUnicodeString` entrega os caracteres direto ao cliente de
    /// entrada de texto do app (inclusive Chromium), sem depender de layout de
    /// teclado nem da área de transferência. `virtualKey: 0` evita que o app
    /// interprete o evento como atalho — inclusive `\n`, que entra como quebra
    /// de linha em vez de disparar o Enter.
    private func insertViaUnicodeTyping(_ text: String, target: FocusedElement) async -> InsertionCheck {
        try? await activateAndWait(pid: target.processID)
        await waitForClearModifiers()

        let placeholder = axPlaceholder(of: target.axElement)
        let beforeRaw = copyStringAttribute(target.axElement, kAXValueAttribute as CFString)
        let before = strippingPlaceholder(from: beforeRaw, placeholder: placeholder)

        // `privateState` isola o estado de modificadores do teclado físico:
        // sem isso, um Shift residual do ⇧ Tab contamina a digitação.
        guard let source = CGEventSource(stateID: .privateState) else {
            logger.error("Não foi possível criar a fonte de eventos para digitar.")
            return .rejected
        }
        source.keyboardType = 0

        for chunk in unicodeChunks(of: text) {
            guard postUnicodeChunk(chunk, source: source) else {
                logger.error("Falha ao criar evento de digitação Unicode.")
                return .rejected
            }
        }

        try? await Task.sleep(for: .milliseconds(220))

        return verifyInsertion(
            in: target,
            beforeRaw: beforeRaw,
            before: before,
            inserted: text,
            placeholder: placeholder
        )
    }

    /// Quebra o texto em blocos curtos: eventos com payload longo demais são
    /// truncados por alguns apps. O corte respeita `Character` para não
    /// separar emoji nem acentos compostos.
    private func unicodeChunks(of text: String, maxUnits: Int = 16) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentUnits = 0

        for character in text {
            let units = character.utf16.count
            if currentUnits + units > maxUnits, !current.isEmpty {
                chunks.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(character)
            currentUnits += units
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func postUnicodeChunk(_ chunk: String, source: CGEventSource) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }

        let units = Array(chunk.utf16)
        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }

        keyDown.flags = []
        keyUp.flags = []

        keyDown.post(tap: .cghidEventTap)
        usleep(1_800)
        keyUp.post(tap: .cghidEventTap)
        usleep(1_800)
        return true
    }

    /// Compara o valor do campo antes e depois para saber se o texto entrou.
    private func verifyInsertion(
        in target: FocusedElement,
        beforeRaw: String?,
        before: String,
        inserted: String,
        placeholder: String?
    ) -> InsertionCheck {
        guard beforeRaw != nil else { return .unknown }

        let afterRaw = copyStringAttribute(target.axElement, kAXValueAttribute as CFString)
        guard let afterRaw else { return .unknown }

        let after = strippingPlaceholder(from: afterRaw, placeholder: placeholder)

        if after.contains(inserted) {
            return .confirmed
        }
        // Campos longos podem truncar o valor AX; qualquer crescimento já indica escrita.
        if after.count > before.count {
            return .confirmed
        }
        return after == before ? .rejected : .unknown
    }

    // MARK: - Clipboard + ⌘V (último recurso)

    /// Cola via ⌘V e **sempre** devolve o clipboard original ao usuário.
    ///
    /// Nunca deixamos a ditagem na área de transferência sem que o usuário peça:
    /// substituir o que ele havia copiado é perda de dado do ponto de vista dele.
    private func insertViaClipboardPaste(_ text: String, target: FocusedElement) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(into: pasteboard)
            throw VoiceInputError.textInsertionFailed
        }

        let placeholder = axPlaceholder(of: target.axElement)
        let beforeRaw = copyStringAttribute(target.axElement, kAXValueAttribute as CFString)
        let before = strippingPlaceholder(from: beforeRaw, placeholder: placeholder)

        defer { snapshot.restore(into: pasteboard) }

        try await activateAndWait(pid: target.processID)
        await waitForClearModifiers()

        let posted = postPasteShortcut(tap: .cghidEventTap)
        if posted {
            lastMethod = .clipboardHID
            logger.notice("Paste enviado via HID tap.")
        } else if postPasteShortcut(tap: .cgSessionEventTap) {
            lastMethod = .clipboardSession
            logger.notice("Paste enviado via session tap.")
        } else if pasteViaSystemEvents() {
            lastMethod = .clipboardSystemEvents
            logger.notice("Paste enviado via System Events.")
        } else {
            throw VoiceInputError.textInsertionFailed
        }

        try? await Task.sleep(for: .milliseconds(220))

        if verifyInsertion(
            in: target,
            beforeRaw: beforeRaw,
            before: before,
            inserted: text,
            placeholder: placeholder
        ) == .rejected {
            logger.notice("⌘V não alterou o campo; inserção considerada falha.")
            throw VoiceInputError.textInsertionFailed
        }
    }

    /// Ativa o app alvo e aguarda ele virar frontmost de fato.
    private func activateAndWait(pid: pid_t) async throws {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            return
        }

        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw VoiceInputError.textInsertionFailed
        }
        app.activate()

        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        logger.warning("App alvo não ficou frontmost; seguindo mesmo assim.")
    }

    /// Envia ⌘V como sequência completa de eventos.
    ///
    /// O Chromium (Electron) reconstrói o estado dos modificadores a partir dos
    /// eventos `flagsChanged`; enviar só key down/up com `flags` definido faz o
    /// Cursor ignorar o atalho.
    private func postPasteShortcut(tap: CGEventTapLocation) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }

        let commandKey = CGKeyCode(kVK_Command)
        let vKey = CGKeyCode(kVK_ANSI_V)

        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false) else {
            return false
        }

        commandDown.type = .flagsChanged
        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        commandUp.type = .flagsChanged
        commandUp.flags = []

        // Pequenas pausas: eventos no mesmo instante são descartados por alguns apps.
        for event in [commandDown, vDown, vUp, commandUp] {
            event.post(tap: tap)
            usleep(18_000)
        }
        return true
    }

    /// Último recurso quando a injeção via CGEvent não é aceita.
    private func pasteViaSystemEvents() -> Bool {
        let script = """
        tell application "System Events" to keystroke "v" using {command down}
        """
        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return false }
        _ = appleScript.executeAndReturnError(&errorInfo)

        if let errorInfo {
            logger.error("System Events falhou: \(String(describing: errorInfo), privacy: .public)")
            return false
        }
        return true
    }

    // MARK: - AX helpers

    private func setAttribute(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, attribute, value) == .success
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else { return nil }
        return value as? String
    }
}
