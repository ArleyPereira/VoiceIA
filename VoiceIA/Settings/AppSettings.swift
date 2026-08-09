import Foundation
import Observation

/// Configurações persistentes da aplicação.
@Observable
@MainActor
final class AppSettings {
    private enum DefaultsKey {
        static let transcriptionLanguage = "settings.transcriptionLanguage"
        static let isTestModeEnabled = "settings.isTestModeEnabled"
        static let keepRecordingsAfterTranscription = "settings.keepRecordingsAfterTranscription"
        static let useLocalWhisperGPU = "settings.useLocalWhisperGPU"
        static let selectedLocalWhisperModel = "settings.selectedLocalWhisperModel"
        static let transcriptionBackend = "settings.transcriptionBackend"
        static let appearanceTheme = "settings.appearanceTheme"
    }

    private let apiKeyStore: any APIKeyProvider
    private let defaults: UserDefaults

    /// Idioma preferido para transcrição (`pt` = português).
    var transcriptionLanguage: String {
        didSet {
            defaults.set(transcriptionLanguage, forKey: DefaultsKey.transcriptionLanguage)
        }
    }

    /// Quando `true`, a transcrição é mock local — **zero** chamada à OpenAI.
    /// Default `true` para proteger créditos até o usuário desligar conscientemente.
    var isTestModeEnabled: Bool {
        didSet {
            defaults.set(isTestModeEnabled, forKey: DefaultsKey.isTestModeEnabled)
        }
    }

    /// Quando `true`, mantém o `.m4a` após transcrever; senão apaga após sucesso.
    var keepRecordingsAfterTranscription: Bool {
        didSet {
            defaults.set(keepRecordingsAfterTranscription, forKey: DefaultsKey.keepRecordingsAfterTranscription)
        }
    }

    /// Preferência para a futura engine Whisper (Metal). Ainda não afeta o ditado.
    var useLocalWhisperGPU: Bool {
        didSet {
            defaults.set(useLocalWhisperGPU, forKey: DefaultsKey.useLocalWhisperGPU)
        }
    }

    /// ID do modelo Whisper local selecionado (`LocalWhisperModel.rawValue`).
    var selectedLocalWhisperModel: String {
        didSet {
            defaults.set(selectedLocalWhisperModel, forKey: DefaultsKey.selectedLocalWhisperModel)
        }
    }

    /// Backend do ditado: `"api"` (OpenAI) ou `"local"` (Whisper no Mac).
    var transcriptionBackend: String {
        didSet {
            defaults.set(transcriptionBackend, forKey: DefaultsKey.transcriptionBackend)
        }
    }

    /// Tema da interface: `system`, `light` ou `dark`.
    var appearanceTheme: String {
        didSet {
            defaults.set(appearanceTheme, forKey: DefaultsKey.appearanceTheme)
        }
    }

    /// Indica se existe API key salva no Keychain (sem expor o valor).
    private(set) var hasAPIKey: Bool

    init(
        apiKeyStore: any APIKeyProvider = OpenAIAPIKeyStore(),
        defaults: UserDefaults = .standard
    ) {
        self.apiKeyStore = apiKeyStore
        self.defaults = defaults

        let storedLanguage = defaults.string(forKey: DefaultsKey.transcriptionLanguage)
        self.transcriptionLanguage = storedLanguage?.isEmpty == false ? storedLanguage! : "pt"

        if defaults.object(forKey: DefaultsKey.isTestModeEnabled) == nil {
            self.isTestModeEnabled = true
        } else {
            self.isTestModeEnabled = defaults.bool(forKey: DefaultsKey.isTestModeEnabled)
        }

        self.keepRecordingsAfterTranscription = defaults.bool(forKey: DefaultsKey.keepRecordingsAfterTranscription)

        if defaults.object(forKey: DefaultsKey.useLocalWhisperGPU) == nil {
            self.useLocalWhisperGPU = true
        } else {
            self.useLocalWhisperGPU = defaults.bool(forKey: DefaultsKey.useLocalWhisperGPU)
        }

        let storedModel = defaults.string(forKey: DefaultsKey.selectedLocalWhisperModel)
        self.selectedLocalWhisperModel = storedModel?.isEmpty == false
            ? storedModel!
            : LocalWhisperModel.largeV3.rawValue

        let storedBackend = defaults.string(forKey: DefaultsKey.transcriptionBackend)
        self.transcriptionBackend = (storedBackend == "local") ? "local" : "api"

        let storedTheme = defaults.string(forKey: DefaultsKey.appearanceTheme)
        if let storedTheme, AppAppearanceTheme(rawValue: storedTheme) != nil {
            self.appearanceTheme = storedTheme
        } else {
            self.appearanceTheme = AppAppearanceTheme.system.rawValue
        }

        self.hasAPIKey = apiKeyStore.hasAPIKey
    }

    /// Relê o estado da API key no Keychain.
    func refreshAPIKeyStatus() {
        hasAPIKey = apiKeyStore.hasAPIKey
    }

    /// Obtém a API key (uso interno pelos serviços de transcrição).
    func openAIAPIKey() throws -> String? {
        try apiKeyStore.apiKey()
    }

    /// Salva a API key no Keychain.
    func saveOpenAIAPIKey(_ key: String) throws {
        try apiKeyStore.saveAPIKey(key)
        refreshAPIKeyStatus()
    }

    /// Remove a API key do Keychain.
    func deleteOpenAIAPIKey() throws {
        try apiKeyStore.deleteAPIKey()
        refreshAPIKeyStatus()
    }
}
