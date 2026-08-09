import Foundation

/// Motor de ASR local por trás de cada item da lista.
enum LocalASREngine: String, Sendable {
    case whisper
    case parakeet
}

/// Catálogo unificado dos modelos locais (Whisper ggml + Parakeet Core ML).
enum LocalTranscriptionModel: String, CaseIterable, Identifiable, Sendable {
    case parakeetTdt06bV3 = "parakeet-tdt-0.6b-v3"
    case largeV3 = "large-v3"
    case largeV3Turbo = "large-v3-turbo"

    var id: String { rawValue }

    var engine: LocalASREngine {
        switch self {
        case .largeV3, .largeV3Turbo:
            return .whisper
        case .parakeetTdt06bV3:
            return .parakeet
        }
    }

    /// Compatível com o store Whisper existente.
    var whisperModel: LocalWhisperModel? {
        LocalWhisperModel(rawValue: rawValue)
    }

    var displayName: String {
        switch self {
        case .largeV3:
            return "Whisper Large v3"
        case .largeV3Turbo:
            return "Whisper Large v3 Turbo"
        case .parakeetTdt06bV3:
            return "NVIDIA Parakeet TDT 0.6B V3"
        }
    }

    var shortDescription: String {
        switch self {
        case .largeV3:
            return "Maior precisão local. Mais lento e exige mais memória."
        case .largeV3Turbo:
            return "Turbo em precisão completa. Fallback rápido e de alta qualidade."
        case .parakeetTdt06bV3:
            return "Ultra-rápido via Core ML (Neural Engine). Multilíngue europeu, ideal para ditado."
        }
    }

    var badgeTitle: String? {
        switch self {
        case .largeV3:
            return "Recomendado"
        case .parakeetTdt06bV3:
            return "Rápido"
        case .largeV3Turbo:
            return nil
        }
    }

    var badgeIsAccent: Bool {
        self == .parakeetTdt06bV3
    }

    var estimatedSizeLabel: String {
        switch self {
        case .largeV3:
            return "~2.9 GB · ~4.7 GB RAM"
        case .largeV3Turbo:
            return "~1.5 GB · ~3 GB RAM"
        case .parakeetTdt06bV3:
            return "~496 MB · multilíngue"
        }
    }

    var systemImageName: String {
        switch engine {
        case .whisper:
            return "cpu"
        case .parakeet:
            return "bolt.fill"
        }
    }

    static var `default`: LocalTranscriptionModel { .largeV3 }
}
