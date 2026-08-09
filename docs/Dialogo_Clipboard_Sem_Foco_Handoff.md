# VoiceIA — Diálogo de fallback (sem campo em foco → clipboard)

Documento de handoff para outro modelo/agente continuar o trabalho.  
Criado em: 2026-08-08  

---

## 0. CORRIGIDO em 2026-08-08 (23:25)

Três causas, todas tratadas:

1. **Diagnóstico cego.** Os logs do caminho de inserção usavam `logger.info`, que
   **não é persistido** por `log show` sem `--info`. Por isso parecia que o código
   nem rodava. Os pontos de decisão passaram para `logger.notice` (persistido).

2. **Alvo inválido aceito.** A validação era por *lista negra*
   (`AXApplication`/`AXWindow`). Com foco no Desktop/Finder o elemento é
   `AXList`/`AXScrollArea`, passava no filtro, o ⌘V ia "no vazio" e o HID
   retornava sucesso — o fallback nunca disparava. Agora a checagem é por
   *lista branca*: papel de texto conhecido **ou** `AXUIElementIsAttributeSettable`
   em `kAXSelectedText`/`kAXValue`. O Cursor (`AXTextArea`) continua funcionando.

3. **Clipboard restaurado por cima.** O `defer` em `insertViaClipboardPaste`
   restaurava o conteúdo antigo 0,4s depois **mesmo quando o paste falhava**,
   apagando a ditagem. Agora só restaura nos caminhos de sucesso.

Reforços:

- `insertTranscribedText` faz fallback para clipboard+diálogo em **qualquer**
  erro de inserção, exceto `accessibilityPermissionDenied`.
- `ClipboardFallbackDialogController` verifica se a janela ficou visível após
  0,35s e, se não ficou, cai para `NSAlert.runModal()`.

Comando de verificação:

```bash
log show --predicate 'subsystem == "dev.arley.santana.VoiceIA"' --last 5m --style compact
```

Esperado no caso sem foco: `Sem campo editável em foco (...)` →
`Fallback de clipboard acionado (copiado=true)` → `Diálogo de clipboard visível.`

---

Criado em: 2026-08-08  
Projeto: `/Users/arley/Developer/VoiceIA`  
Bundle ID: `dev.arley.santana.VoiceIA`  
App instalado para testes: `/Applications/VoiceIA.app`

---

## 1. O que o usuário precisa (requisito)

Quando o usuário **termina uma ditagem** (grava → para com ⇧ Tab) e **não há nenhum campo de texto / input em foco** no macOS:

1. A **transcrição deve continuar** (OpenAI ou modo teste).
2. O texto **não deve se perder**.
3. O texto deve ser **copiado para a área de transferência** (clipboard).
4. Deve aparecer um **diálogo fixo** (não fecha sozinho, não some em 2s):
   - Explicar que **não havia aplicativo/campo em foco**.
   - Explicar que o texto **foi copiado para a área de transferência**.
   - Orientar a colar com **⌘V** (Cmd+V).
   - Ideal: mostrar um **preview** do texto.
   - Só fecha quando o usuário confirma (ex.: botão “Entendi”) ou fecha a janela.
5. **Não** deve aparecer só o HUD flutuante “Erro” que auto-desaparece.

Fluxo esperado:

```
Gravar → Transcrever → Tentar inserir no foco
                         ↓ falhou (sem foco)
                       Copiar para clipboard
                         ↓
                       Mostrar diálogo fixo
                         ↓
                       Usuário cola com ⌘V onde quiser
```

---

## 2. Sintoma atual (ainda quebrado)

Em testes recentes (2026-08-08 ~23:20–23:22):

- Usuário grava **sem** campo em foco.
- **O diálogo não aparece.**
- Em alguns casos o HUD de “Erro” antigo aparecia; em outros o app fingia sucesso.

Confirmação parcial via `log show` (sessão anterior, PID antigo):

```
[accessibility] Nenhum elemento focado encontrado
[insertion] Nenhum alvo de inserção encontrado.
```

Na sessão **depois** do primeiro patch do diálogo (PID 25333), os logs mostraram atividade de **pasteboard + HID ⌘V** sem log de “nenhum alvo” — ou seja, o caminho caía em “paste cego” e tratava como sucesso, **sem** abrir o diálogo.

---

## 3. Arquivos relevantes

| Arquivo | Papel |
|---|---|
| `VoiceIA/App/AppState.swift` | Pipeline ditado → transcrição → inserção; chama o diálogo no `catch` de `.noFocusedElement` |
| `VoiceIA/UI/ClipboardFallbackDialogController.swift` | Janela/diálogo SwiftUI + `NSPanel` |
| `VoiceIA/Input/DefaultTextInsertionService.swift` | Tenta AX e depois clipboard+⌘V; deve lançar `.noFocusedElement` quando não há alvo real |
| `VoiceIA/Accessibility/AccessibilityService.swift` | Resolve elemento focado via AX |
| `VoiceIA/App/VoiceInputError.swift` | Caso `.noFocusedElement` |
| `VoiceIA/Input/ClipboardSnapshot.swift` | Snapshot do clipboard (hoje restaura o conteúdo antigo ~0,4s após paste) |
| `VoiceIA/UI/Recording/RecordingOverlayController.swift` | HUD; estado `.error` auto-some via `scheduleReturnToIdle` |

Logs do app (OSLog):

```bash
log show --predicate 'subsystem == "dev.arley.santana.VoiceIA"' --last 10m --style compact
```

Categorias: `accessibility`, `insertion`, `transcription`, `audio`.

---

## 4. O que já foi implementado

### 4.1 Gatilho em `AppState.insertTranscribedText`

Se a inserção lança `VoiceInputError.noFocusedElement`:

- Copia o texto para `NSPasteboard.general`
- Chama `clipboardFallbackDialog.present(transcribedText:)`
- **Não** chama `scheduleReturnToIdle` (não auto-fecha)

Trecho atual (resumo):

```swift
} catch let error as VoiceInputError where error == .noFocusedElement {
    presentClipboardFallback(for: text)
}
```

`presentClipboardFallback` limpa o pasteboard, seta o string, e agenda o `present` no main queue.

### 4.2 UI: `ClipboardFallbackDialogController`

Criado em:

`VoiceIA/UI/ClipboardFallbackDialogController.swift`

- `NSPanel` (depois de tentativa com `NSWindow`)
- Visual alinhado às Settings (`SettingsBackground`, `GradientButtonStyle`)
- Título: “Sem campo em foco”
- Texto explicando clipboard + ⌘V
- Preview do texto (até 3 linhas)
- Botão “Entendi”
- `activationPolicy(.regular)` + `activate(ignoringOtherApps:)`
- `level = .modalPanel`
- Não fecha sozinho

O projeto usa `PBXFileSystemSynchronizedRootGroup` — arquivo novo entra no target automaticamente.

### 4.3 Tentativas de corrigir o gatilho (porque o diálogo não abria)

**Problema raiz descoberto:**  
`AccessibilityService.focusedElement()` fazia fallback para o **app frontmost inteiro** quando não havia `kAXFocusedUIElement`:

```swift
// REMOVIDO (era o bug)
// return makeFocused(descend(appElement))
```

Isso fazia `DefaultTextInsertionService` achar que havia alvo, disparar clipboard+⌘V, considerar sucesso (HID retorna `true` mesmo sem campo) e **nunca** lançar `.noFocusedElement`.  
Além disso, `insertViaClipboardPaste` tem `defer` que **restaura o clipboard antigo após 0,4s**, apagando o texto da ditagem.

**Mudanças feitas em seguida:**

1. Removido o fallback “usar o app como alvo” em `AccessibilityService` → agora lança `.noFocusedElement`.
2. Em `DefaultTextInsertionService`:
   - `preferredTarget(live:captured:)` prefere alvo editável.
   - `isContainerOnly` trata `AXApplication` / `AXWindow` como inválidos para inserção → lança `.noFocusedElement`.
3. Diálogo reforçado com `NSPanel` + `DispatchQueue.main.async`.

**Status:** usuário reportou que **ainda assim o diálogo não apareceu**. Trabalho incompleto.

---

## 5. Hipóteses ainda abertas (para o próximo agente)

1. **O `catch` de `.noFocusedElement` não está sendo atingido**  
   Outro erro sobe (`textInsertionFailed`, erro genérico, ou “sucesso” falso do HID).  
   → Instrumentar logs explícitos em `insertTranscribedText` e no início de `presentClipboardFallback` / `present`.

2. **Clipboard paste ainda “sucede” com alvo ruim**  
   Ex.: foco em `AXGroup` / lista do Finder / Control Center — não é Application/Window, então passa em `isContainerOnly`, HID “sucede”, diálogo não abre.  
   → Ampliar critério de “sem input” OU tratar falha de inserção (qualquer uma, exceto permissão) como fallback de clipboard+diálogo.

3. **Janela criada mas invisível**  
   App é Menu Bar (`.accessory`). Painel pode estar atrás, em outro Space, ou com tamanho/hosting zerado.  
   → Testar `NSAlert.runModal()` como prova de conceito (sempre modal e visível). Se `NSAlert` funcionar, o bug é só apresentação da UI custom.

4. **Corrida com restauração do clipboard**  
   Se algum caminho ainda chama `insertViaClipboardPaste` antes do fallback, o `defer` restaura o pasteboard e apaga a ditagem.  
   → No fallback, **não** restaurar clipboard; garantir que o texto permanece até o usuário colar.

5. **Transcrição falhou antes da inserção**  
   Aí o fluxo nem chega em `insertTranscribedText`.  
   → Conferir logs de `transcription` na mesma janela de tempo.

6. **Foco capturado no *início* da gravação**  
   `captureFocusBeforeRecordingBestEffort` pode guardar um alvo antigo “válido”; no fim a inserção usa esse alvo e “sucede” no app errado.  
   → Preferir foco **no momento da inserção**; só usar `captured` se ainda for editável e útil.

---

## 6. Alternativas já consideradas / parciais

| Abordagem | Resultado |
|---|---|
| HUD `.error` + `scheduleReturnToIdle(2s)` | Ruim: some sozinho; não fala de clipboard |
| Diálogo SwiftUI + `NSWindow` | Implementado; usuário não viu |
| Diálogo SwiftUI + `NSPanel` `.modalPanel` | Implementado; usuário ainda não viu |
| Remover fallback AX → app frontmost | Feito; pode não ser suficiente sozinho |
| Bloquear papéis Application/Window | Feito; papéis intermediários ainda escapam |
| `NSAlert` nativo | **Ainda não testado** — recomendado como próximo passo de prova |
| Sempre copiar + diálogo se inserção falhar | **Ainda não feito** — alinhado ao pedido do usuário e mais robusto |

---

## 7. Recomendação para o próximo agente

Ordem sugerida:

1. **Prova rápida com `NSAlert.runModal()`** dentro de `presentClipboardFallback`  
   Se o alerta nativo aparecer, o gatilho está OK e o problema é só a UI custom.  
   Se nem o `NSAlert` aparecer, o `catch` não está rodando.

2. **Alargar o fallback** em `insertTranscribedText`:
   - Em **qualquer** falha de inserção (exceto talvez `.accessibilityPermissionDenied`), copiar texto + mostrar diálogo.
   - Opcional: também se a inserção “sucede” mas o alvo não era editável.

3. **Logs obrigatórios** (temporários):
   ```swift
   logger.info("insert catch: \(error)")
   logger.info("presentClipboardFallback chamado")
   logger.info("dialog present() executado")
   ```

4. **Garantir clipboard**:
   - No fallback, setar o texto **depois** de qualquer `insertViaClipboardPaste`.
   - Não agendar restore do `ClipboardSnapshot` no caminho de fallback.

5. **Critério de “sem input”** mais seguro:
   - Sem `kAXFocusedUIElement` → fallback.
   - Papel não editável e AX write falhou → fallback (não confiar só no retorno do HID).

6. Manter o visual elegante do diálogo custom **depois** de provar que o gatilho funciona.

---

## 8. Como reproduzir

1. Abrir `/Applications/VoiceIA.app` (Menu Bar).
2. Garantir API key **ou** modo teste ligado (Settings).
3. Clicar na **área de trabalho / Finder**, sem campo de texto focado.
4. ⇧ Tab → falar → ⇧ Tab de novo.
5. **Esperado:** diálogo fixo + texto no clipboard (⌘V cola em Notas).  
   **Atual:** diálogo não aparece (bug).

Logs:

```bash
log show --predicate 'subsystem == "dev.arley.santana.VoiceIA"' --last 5m --style compact
```

Rebuild / instalar (padrão do projeto):

```bash
xcodebuild -project VoiceIA.xcodeproj -scheme VoiceIA -configuration Debug -destination 'platform=macOS' build
# copiar de BUILT_PRODUCTS_DIR/VoiceIA.app → /Applications/VoiceIA.app, codesign, open
```

Script de instalação (precisa `BUILT_PRODUCTS_DIR` do Xcode): `scripts/install-dev-app.sh`.

---

## 9. Critério de aceite

- [ ] Sem campo em foco, após ditagem bem-sucedida, o diálogo **sempre** aparece.
- [ ] O diálogo **não** fecha sozinho.
- [ ] O texto está na área de transferência e ⌘V cola o conteúdo correto.
- [ ] Com campo em foco (Notas, Cursor, etc.), o fluxo normal de inserção **continua** funcionando (sem diálogo indevido).
- [ ] Permissão de Acessibilidade negada continua com mensagem adequada (não misturar com este fallback, a menos que se decida copiar também nesse caso).

---

## 10. Contexto de produto (útil)

- Atalho: **⇧ Tab** (toggle gravar / enviar). Pause/continua no HUD.
- App Menu Bar Extra; janelas usam `NSApp.setActivationPolicy(.regular)` ao abrir e voltam para `.accessory` ao fechar se não houver outras janelas.
- Settings reformuladas com sidebar + visual “glass” (`SettingsDesign.swift`).
- Inserção no Cursor (Electron) já foi resolvida antes — ver `docs/Cursor_Insercao_Texto_Handoff.md`. Não reverter essa lógica ao corrigir o fallback sem foco.
