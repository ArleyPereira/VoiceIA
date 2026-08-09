import Carbon
import Foundation

/// Monitoramento global do atalho ⇧ Tab (push-to-talk).
nonisolated final class GlobalHotkeyService: GlobalHotkeyServiceProtocol, @unchecked Sendable {
    /// Chamado quando ⇧ Tab é pressionado.
    var onPressed: (@Sendable () -> Void)?

    /// Chamado quando ⇧ Tab é solto.
    var onReleased: (@Sendable () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isHotkeyHeld = false
    private let lock = NSLock()

    private let hotKeyID = EventHotKeyID(
        signature: FourCharCode("VIA1"),
        id: 1
    )

    func start() {
        stop()
        installHandler()
        registerHotKey()
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }

        resetHoldState()
    }

    func resetHoldState() {
        lock.lock()
        isHotkeyHeld = false
        lock.unlock()
    }

    func forceHeld() {
        lock.lock()
        isHotkeyHeld = true
        lock.unlock()
    }

    deinit {
        stop()
    }

    // MARK: - Privado

    private func registerHotKey() {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            HotkeyConfiguration.keyCode,
            HotkeyConfiguration.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard status == noErr else {
            assertionFailure("Falha ao registrar atalho global: \(status)")
            return
        }

        hotKeyRef = ref
    }

    private func installHandler() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var handler: EventHandlerRef?

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }

                let service = Unmanaged<GlobalHotkeyService>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                let kind = GetEventKind(event)
                if kind == UInt32(kEventHotKeyPressed) {
                    service.handlePressed()
                } else if kind == UInt32(kEventHotKeyReleased) {
                    service.handleReleased()
                }

                return noErr
            },
            2,
            &eventTypes,
            userData,
            &handler
        )

        guard status == noErr else {
            assertionFailure("Falha ao instalar handler do atalho: \(status)")
            return
        }

        handlerRef = handler
    }

    private func handlePressed() {
        lock.lock()
        let alreadyHeld = isHotkeyHeld
        if !alreadyHeld {
            isHotkeyHeld = true
        }
        lock.unlock()

        guard !alreadyHeld else { return }
        onPressed?()
    }

    private func handleReleased() {
        lock.lock()
        let wasHeld = isHotkeyHeld
        isHotkeyHeld = false
        lock.unlock()

        guard wasHeld else { return }
        onReleased?()
    }
}

private extension FourCharCode {
    init(_ string: String) {
        precondition(string.utf8.count == 4)
        var result: FourCharCode = 0
        for byte in string.utf8 {
            result = (result << 8) + FourCharCode(byte)
        }
        self = result
    }
}
