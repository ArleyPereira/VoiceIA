import AppKit
import SwiftUI

/// HUD de gravação: waveform, duração e pause/continua,
/// com borda em gradiente que circula conforme a voz.
struct RecordingOverlay: View {
    @Bindable var appState: AppState
    @State private var glow = OverlayGlowDriver()

    private static let barSize = CGSize(width: 300, height: 52)

    /// Cores do gradiente giratório (a primeira repete no fim para fechar o ciclo).
    private static let glowColors: [Color] = [
        Color(red: 0.30, green: 0.85, blue: 1.00),
        Color(red: 0.42, green: 0.45, blue: 1.00),
        Color(red: 0.72, green: 0.38, blue: 1.00),
        Color(red: 1.00, green: 0.42, blue: 0.78),
        Color(red: 0.30, green: 0.85, blue: 1.00)
    ]

    var body: some View {
        Group {
            if isCapturing {
                recordingBar
            } else {
                statusBar
            }
        }
        .frame(width: Self.barSize.width, height: Self.barSize.height)
        .onAppear { syncGlowDriver() }
        .onDisappear { glow.stop() }
        .onChange(of: appState.recordingState) { _, _ in syncGlowDriver() }
    }

    private var isCapturing: Bool {
        appState.recordingState == .recording || appState.recordingState == .paused
    }

    /// Mantém a animação só enquanto o HUD de captura está à mostra.
    private func syncGlowDriver() {
        if isCapturing {
            glow.start()
        } else {
            glow.stop()
        }
    }

    private var recordingBar: some View {
        HStack(spacing: 10) {
            WaveformView(isActive: appState.recordingState == .recording, barCount: 42)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)

            Text(appState.recordingDurationText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .monospacedDigit()
                .allowsHitTesting(false)

            pauseButton
        }
        .padding(.horizontal, 14)
        .frame(width: Self.barSize.width, height: Self.barSize.height)
        .background {
            ZStack {
                // Só o fundo: blur do conteúdo atrás da janela + tint escuro.
                FrostedBackground()
                Capsule().fill(barFill.opacity(0.55))
                innerGlow
            }
            .clipShape(Capsule())
        }
        .overlay { animatedBorder }
    }

    private var pauseButton: some View {
        Button {
            Task {
                if appState.recordingState == .paused {
                    await appState.resumeDictation()
                } else {
                    await appState.pauseDictation()
                }
            }
        } label: {
            Image(systemName: appState.recordingState == .paused ? "play.fill" : "pause.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.16)))
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(appState.recordingState == .paused ? "Continuar" : "Pausar")
    }

    /// Manchas coloridas desfocadas que passeiam por dentro da cápsula.
    private var innerGlow: some View {
        ZStack {
            glowBlob(color: Self.glowColors[0], angleOffset: 0)
            glowBlob(color: Self.glowColors[2], angleOffset: 130)
            glowBlob(color: Self.glowColors[3], angleOffset: 245)
        }
        .blur(radius: 26)
        .opacity(0.34 + glow.intensity * 0.42)
        .blendMode(.plusLighter)
    }

    private func glowBlob(color: Color, angleOffset: Double) -> some View {
        let radians = (glow.phase + angleOffset) * .pi / 180
        let horizontalReach = Self.barSize.width * 0.36

        return Circle()
            .fill(color)
            .frame(width: 96, height: 96)
            .offset(x: cos(radians) * horizontalReach, y: sin(radians) * 12)
    }

    /// Borda com gradiente angular girando + halo interno.
    private var animatedBorder: some View {
        let gradient = AngularGradient(
            colors: Self.glowColors,
            center: .center,
            angle: .degrees(glow.phase)
        )

        return Capsule()
            .strokeBorder(gradient, lineWidth: 1.4)
            .overlay {
                Capsule()
                    .strokeBorder(gradient, lineWidth: 3.5)
                    .blur(radius: 5)
                    .opacity(0.45 + glow.intensity * 0.45)
            }
            .allowsHitTesting(false)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: trailingSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accentColor)

            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(width: 220, height: Self.barSize.height)
        .background {
            ZStack {
                FrostedBackground()
                Capsule().fill(barFill.opacity(0.55))
            }
            .clipShape(Capsule())
        }
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var barFill: Color {
        Color(red: 0.07, green: 0.08, blue: 0.10)
    }

    private var accentColor: Color {
        switch appState.recordingState {
        case .success:
            return Color(red: 0.45, green: 0.92, blue: 0.62)
        case .error:
            return Color(red: 1.00, green: 0.62, blue: 0.28)
        case .paused:
            return Color(red: 1.00, green: 0.78, blue: 0.35)
        default:
            return Color(red: 0.30, green: 0.88, blue: 0.80)
        }
    }

    private var trailingSymbol: String {
        switch appState.recordingState {
        case .success:
            return "checkmark"
        case .error:
            return "exclamationmark"
        case .paused:
            return "pause.fill"
        default:
            return "mic.fill"
        }
    }

    private var title: String {
        switch appState.recordingState {
        case .success:
            return "Concluído"
        case .error:
            return "Erro"
        case .paused:
            return "Pausado"
        case .transcribing:
            return "Transcrevendo…"
        case .inserting:
            return "Inserindo…"
        default:
            return ""
        }
    }
}

/// Blur translúcido do que está atrás do painel (não afeta texto/waveform).
private struct FrostedBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
    }
}
