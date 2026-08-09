import AppKit

/// Configura o ciclo de vida do app como acessório da barra de menu.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Cobre force quit / crash: parciais órfãs não ficam no disco.
        Task { @MainActor in
            LocalWhisperModelStore.shared.purgeIncompleteDownloads()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cancela downloads e apaga .partial de forma definitiva (sem Lixeira).
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            LocalWhisperModelStore.shared.cancelAllDownloadsAndPurgePartials()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
