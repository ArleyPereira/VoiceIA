import Foundation
import Observation

/// Gira o gradiente da borda do HUD e mede a “energia” da voz.
///
/// A rotação acelera conforme o usuário fala mais alto/rápido; no silêncio
/// mantém um giro lento, só para a barra não ficar estática.
@Observable
@MainActor
final class OverlayGlowDriver {
    /// Ângulo atual do gradiente, em graus.
    private(set) var phase: Double = 0

    /// Nível de voz suavizado (0...1) usado para intensidade e velocidade.
    private(set) var intensity: Double = 0

    private var timer: Timer?
    private var lastTick: Date?

    /// Graus por segundo no silêncio absoluto.
    private let baseSpeed: Double = 40

    /// Acréscimo máximo de velocidade quando a voz está no pico.
    private let voiceSpeedBoost: Double = 520

    func start() {
        guard timer == nil else { return }
        lastTick = Date()

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTick = nil
        intensity = 0
    }

    private func tick() {
        let now = Date()
        let delta = min(0.1, now.timeIntervalSince(lastTick ?? now))
        lastTick = now

        let level = Double(LiveAudioMeter.shared.level)
        // Suaviza: sobe rápido na fala, desce devagar para o brilho não piscar.
        let coefficient = level > intensity ? 0.35 : 0.12
        intensity += (level - intensity) * coefficient

        let degreesPerSecond = baseSpeed + intensity * voiceSpeedBoost
        phase = (phase + degreesPerSecond * delta).truncatingRemainder(dividingBy: 360)
    }
}
