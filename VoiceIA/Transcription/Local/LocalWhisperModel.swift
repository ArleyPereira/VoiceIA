import Foundation

/// Modelos Whisper locais disponíveis para download (ggml / whisper.cpp).
enum LocalWhisperModel: String, CaseIterable, Identifiable, Sendable {
    case largeV3 = "large-v3"
    case largeV3Turbo = "large-v3-turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .largeV3: return "Whisper Large v3"
        case .largeV3Turbo: return "Whisper Large v3 Turbo"
        }
    }

    var shortDescription: String {
        switch self {
        case .largeV3:
            return "Maior precisão local. Mais lento e exige mais memória."
        case .largeV3Turbo:
            return "Turbo em precisão completa. Fallback rápido e de alta qualidade."
        }
    }

    var isRecommended: Bool {
        self == .largeV3
    }

    /// Nome do arquivo em disco (mesmo padrão do whisper.cpp).
    var fileName: String {
        "ggml-\(rawValue).bin"
    }

    /// URL oficial no Hugging Face (ggerganov/whisper.cpp).
    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    /// Tamanho aproximado para exibição (bytes).
    var estimatedByteCount: Int64 {
        switch self {
        case .largeV3: return 3_097_000_000 // ~2.9 GiB
        case .largeV3Turbo: return 1_620_000_000 // ~1.5 GiB
        }
    }

    var estimatedSizeLabel: String {
        switch self {
        case .largeV3: return "~2.9 GB · ~4.7 GB RAM"
        case .largeV3Turbo: return "~1.5 GB · ~3 GB RAM"
        }
    }
}
