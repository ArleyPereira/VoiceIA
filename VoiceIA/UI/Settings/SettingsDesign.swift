import AppKit
import SwiftUI

/// Paleta e componentes visuais compartilhados da janela de configurações.
/// Segue a mesma linguagem do HUD flutuante: fundo escuro com blur e
/// acentos em ciano → azul → roxo → rosa.
enum SettingsTheme {
    static let cyan = Color(red: 0.30, green: 0.85, blue: 1.00)
    static let blue = Color(red: 0.42, green: 0.45, blue: 1.00)
    static let purple = Color(red: 0.72, green: 0.38, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.42, blue: 0.78)

    static let accentGradient = LinearGradient(
        colors: [cyan, blue, purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardCornerRadius: CGFloat = 16
    static let fieldCornerRadius: CGFloat = 10

    /// Traço fino usado nas bordas de campos e cartões.
    static let hairline: CGFloat = 0.8
}

// MARK: - Fundo

/// Fundo da janela: material translúcido + manchas de cor bem suaves.
struct SettingsBackground: View {
    var body: some View {
        ZStack {
            SettingsVisualEffect()

            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.08, blue: 0.12).opacity(0.94),
                    Color(red: 0.05, green: 0.05, blue: 0.08).opacity(0.97)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            colorBlob(SettingsTheme.blue, x: -170, y: -190, size: 380)
            colorBlob(SettingsTheme.purple, x: 210, y: -120, size: 320)
            colorBlob(SettingsTheme.cyan, x: -120, y: 240, size: 300)
            colorBlob(SettingsTheme.pink, x: 240, y: 250, size: 260)
        }
        .ignoresSafeArea()
    }

    private func colorBlob(_ color: Color, x: CGFloat, y: CGFloat, size: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .offset(x: x, y: y)
            .blur(radius: 110)
            .opacity(0.22)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }
}

/// Blur nativo do AppKit (o SwiftUI `Material` sozinho não pega o fundo da janela).
struct SettingsVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
    }
}

// MARK: - Cartão

/// Bloco de conteúdo com vidro fosco e borda fininha.
struct SettingsCard<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let title {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                .fill(.white.opacity(0.05))
                .background(
                    RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: SettingsTheme.hairline)
        }
    }
}

// MARK: - Campos

/// Campo de texto alto, com borda fina e fundo translúcido.
struct GlassFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background {
                RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                    .fill(.white.opacity(0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: SettingsTheme.hairline)
            }
    }
}

// MARK: - Botões

/// Botão principal com gradiente da marca.
struct GradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background {
                Capsule().fill(SettingsTheme.accentGradient)
            }
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.22), lineWidth: SettingsTheme.hairline)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Botão secundário discreto (contorno fino).
struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                Capsule().fill(.white.opacity(configuration.isPressed ? 0.12 : 0.06))
            }
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.16), lineWidth: SettingsTheme.hairline)
            }
            .opacity(isEnabled ? 1 : 0.35)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Peças menores

/// Etiqueta de status (verde quando tudo certo, laranja quando pendente).
struct StatusPill: View {
    let text: String
    let isPositive: Bool

    var body: some View {
        let color = isPositive
            ? Color(red: 0.40, green: 0.90, blue: 0.62)
            : Color(red: 1.00, green: 0.70, blue: 0.35)

        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: SettingsTheme.hairline))
    }
}

/// Linha com título, descrição e um controle à direita.
/// O ícone à esquerda é opcional (usado para sinalizar permissões).
struct SettingsRow<Trailing: View>: View {
    let title: String
    var description: String?
    var icon: String?
    var iconColor: Color = .white
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))

                if let description {
                    Text(description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            trailing
        }
    }
}

/// Ícone e cor de uma permissão, conforme esteja concedida ou não.
enum PermissionIndicator {
    static func symbol(isGranted: Bool) -> String {
        isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    static func color(isGranted: Bool) -> Color {
        isGranted
            ? Color(red: 0.40, green: 0.90, blue: 0.62)
            : Color(red: 1.00, green: 0.70, blue: 0.35)
    }
}

/// Separador quase invisível entre linhas do mesmo cartão.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.07))
            .frame(height: 1)
    }
}
