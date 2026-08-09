import Foundation

/// Detecta silêncio / alucinações típicas do Whisper antes de inserir texto.
enum SpeechPresenceAnalyzer {
    /// RMS abaixo disso + pico baixo → gravação praticamente muda.
    private static let silenceRMSThreshold: Double = 0.010
    private static let silencePeakThreshold: Float = 0.050

    /// Fração mínima de amostras “audíveis” para considerar que houve fala.
    private static let minimumLoudFrameRatio: Double = 0.012
    private static let loudSampleThreshold: Float = 0.022

    /// Frases curtas que o Whisper costuma inventar no silêncio (PT/EN).
    private static let hallucinationPhrases: Set<String> = [
        "obrigado",
        "obrigada",
        "obrigado.",
        "thanks",
        "thank you",
        "thank you.",
        "thanks for watching",
        "thank you for watching",
        "thanks for watching.",
        "legenda",
        "legendas",
        "legendas pelo trabalho de jose",
        "subtitles",
        "subtitle",
        "amém",
        "amen",
        "you",
        "the end",
        "fim",
        "inscreva-se",
        "subscribe",
        "music",
        "applause",
        "silêncio",
        "silence"
    ]

    /// `true` se o PCM 16 kHz mono tem energia suficiente de fala.
    static func hasSpeechEnergy(in samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }

        var sumSquares: Double = 0
        var peak: Float = 0
        var loudFrames = 0

        for sample in samples {
            let absolute = abs(sample)
            if absolute > peak {
                peak = absolute
            }
            sumSquares += Double(sample) * Double(sample)
            if absolute >= loudSampleThreshold {
                loudFrames += 1
            }
        }

        let rms = sqrt(sumSquares / Double(samples.count))
        let loudRatio = Double(loudFrames) / Double(samples.count)

        if rms < silenceRMSThreshold && peak < silencePeakThreshold {
            return false
        }
        if loudRatio < minimumLoudFrameRatio && rms < silenceRMSThreshold * 1.6 {
            return false
        }
        return true
    }

    /// Normaliza o texto para comparar com alucinações conhecidas.
    static func normalizedTranscription(_ text: String) -> String {
        let folded = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        let collapsed = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed
    }

    /// `true` se o texto parece alucinação clássica de silêncio do Whisper.
    static func looksLikeSilenceHallucination(_ text: String) -> Bool {
        let normalized = normalizedTranscription(text)
        guard !normalized.isEmpty else { return true }
        if hallucinationPhrases.contains(normalized) {
            return true
        }
        // Uma única palavra muito curta e genérica.
        let tokens = normalized.split(separator: " ")
        if tokens.count == 1, let only = tokens.first, only.count <= 3 {
            return ["ok", "ah", "oh", "uh", "hm", "um", "eh"].contains(String(only))
        }
        return false
    }
}
