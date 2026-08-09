import Foundation

/// Contrato para registro do atalho global push-to-talk.
protocol GlobalHotkeyServiceProtocol: AnyObject {
    var onPressed: (@Sendable () -> Void)? { get set }
    var onReleased: (@Sendable () -> Void)? { get set }

    /// Inicia o monitoramento do atalho global.
    func start()

    /// Encerra o monitoramento do atalho global.
    func stop()

    /// Limpa o estado interno de “tecla segurada”.
    func resetHoldState()

    /// Força o estado de tecla segurada (após release espúrio).
    func forceHeld()
}
