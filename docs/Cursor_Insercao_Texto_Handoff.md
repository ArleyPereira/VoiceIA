# VoiceIA — Falha na inserção de texto no Cursor (Electron)

Documento de handoff para diagnóstico avançado.  
Atualizado em: 2026-08-08  
Projeto: `/Users/arley/Developer/VoiceIA`  
Bundle ID: `dev.arley.santana.VoiceIA`

---

## 0. RESOLVIDO em 2026-08-08

A inserção passou a funcionar no Cursor (validada em teste real). Duas causas
independentes, ambas corrigidas:

1. **Falso sucesso do Accessibility.** No Cursor, `AXUIElementSetAttributeValue`
   retorna `.success` sem alterar o campo. O código confiava nesse retorno e
   considerava a inserção concluída, então o fallback de clipboard nunca rodava.
   Correção: toda escrita via AX é verificada por releitura de `kAXValueAttribute`
   (`didValueChange`); sem mudança real, cai para o clipboard.

2. **⌘V incompleto para Chromium.** O Electron reconstrói o estado dos
   modificadores a partir de eventos `flagsChanged`. Enviar apenas key down/up
   com `flags = .maskCommand` não registra o Command. Correção: sequência
   completa Command down (`flagsChanged`) → V down → V up → Command up, com
   pausas de 18 ms entre eventos.

Correções de apoio:

- `AccessibilityService.descend` desce aplicativo → janela → elemento focado
  (antes parava no `AXApplication` em Electron).
- Antes do paste, aguarda o app alvo virar frontmost de fato (poll), em vez de
  `sleep` fixo.
- Removido o clique sintético do mouse (movia o cursor do usuário).
- `InsertionMethod` registra e exibe a estratégia usada.
- Cópia única do app em `/Applications/VoiceIA.app`; a do DerivedData do Xcode
  foi removida por invalidar o TCC a cada rebuild.

Log de confirmação:

```
Foco capturado: Cursor · AXTextArea
Alvo: Cursor · AXTextArea pid=57190
Accessibility não alterou o campo; usando clipboard + ⌘V.
Paste enviado via HID tap.
```

O conteúdo abaixo é o histórico do diagnóstico.

---

## 1. Resumo do problema

O VoiceIA é um menu bar app macOS (SwiftUI / AppKit) estilo Super Whisper:

1. Usuário foca um campo de texto  
2. Segura `⇧ Tab` (push-to-talk) → grava microfone  
3. Solta → (hoje) cola um **texto de teste fixo** no campo focado  
4. Futuro (Etapa 7): OpenAI Whisper → texto real da fala

### O que funciona

| Cenário | Resultado |
|---|---|
| Gravação de áudio (Fifine USB, microfone padrão) | OK — waveform anima, `.m4a` com áudio real |
| Permissão de microfone | OK |
| Permissão de Acessibilidade (`AXIsProcessTrusted`) | OK (após reset TCC + app em `/Applications`) |
| Inserção no **Notas** (app nativo macOS) via fluxo `⇧ Tab` | OK |
| Menu **“Inserir texto de teste (3s)”** (sem gravar) | OK em alguns contextos (incluindo Cursor, em testes anteriores) |
| Texto inserido hoje | Sempre: `Olá, este é um teste do VoiceIA.` (esperado — OpenAI ainda não existe) |

### O que NÃO funciona

| Cenário | Resultado |
|---|---|
| Fluxo completo `⇧ Tab` → gravar → soltar → inserir no **Cursor** (chat input / “Send follow-up”) | **Falha** — áudio/waveform OK, texto **não aparece** no input |
| Expectativa do usuário de ver a fala transcrita | Ainda não implementado (só texto fixo de teste das Etapas 5–6) |

**Conclusão atual:** o pipeline de áudio está saudável. O problema restante é **inserção de texto em apps Electron/Chromium (Cursor)** no caminho pós-gravação com atalho global `⇧ Tab`.

---

## 2. Ambiente

- macOS Darwin 25.x (macOS 26.x SDK no build)
- App: Menu Bar Extra, `NSApp.setActivationPolicy(.accessory)`
- Code sign: **ad-hoc** (`Signature=adhoc`, sem `DEVELOPMENT_TEAM`, zero identities de codesign na máquina)
- Sandbox: **desligado** (`ENABLE_APP_SANDBOX = NO`)
- Entitlement de mic: `com.apple.security.device.audio-input` (hífen; a chave com ponto estava errada antes)
- Caminho estável preferido para TCC: `/Applications/VoiceIA.app`
- Também existe build em:  
  - `/Users/arley/Developer/VoiceIA/.derivedData/Build/Products/Debug/VoiceIA.app`  
  - `/Users/arley/Library/Developer/Xcode/DerivedData/VoiceIA-.../Build/Products/Debug/VoiceIA.app` (já causou confusão com binário antigo)

### Dispositivos de áudio observados

- `fifine Microphone` (padrão do sistema) — captura OK  
- `Microfone (MacBook Air)`  
- `Microsoft Teams Audio` (loopback) — risco de seleção errada se não casar UID do CoreAudio

---

## 3. Arquitetura relevante

```
⇧ Tab DOWN
  → captureFocusBeforeRecordingBestEffort()
  → AudioRecorder.startRecording() (AVCaptureSession + AVAssetWriter AAC 16 kHz)
  → overlay HUD (waveform)

⇧ Tab UP
  → stopRecording()
  → insertStage56TestText()
       → DefaultTextInsertionService.insert(text:into:)
            1) AX selectedText / rewrite value (só roles de texto)
            2) clipboard + ⌘V (CGEvent HID / session)
            3) clipboard + System Events keystroke
```

### Arquivos-chave

| Arquivo | Papel |
|---|---|
| `VoiceIA/App/AppState.swift` | Orquestra hotkey, gravação, captura de foco, inserção pós-stop |
| `VoiceIA/Accessibility/AccessibilityService.swift` | Resolve foco (system-wide → app focado → app da frente) |
| `VoiceIA/Accessibility/AccessibilityPermission.swift` | `AXIsProcessTrusted` / prompt / abrir Ajustes |
| `VoiceIA/Input/DefaultTextInsertionService.swift` | Inserção AX + clipboard/paste |
| `VoiceIA/Input/ClipboardSnapshot.swift` | Preserva/restaura pasteboard |
| `VoiceIA/Hotkey/GlobalHotkeyService.swift` | Carbon `RegisterEventHotKey` (⇧ Tab) |
| `VoiceIA/UI/Recording/RecordingOverlayController.swift` | `NSPanel` `.nonactivatingPanel`, `orderFrontRegardless`, `ignoresMouseEvents` |
| `VoiceIA/Audio/AudioRecorder.swift` | Captura (já validada) |

Texto fixo de teste:

```swift
AppState.stage56TestInsertionText = "Olá, este é um teste do VoiceIA."
```

---

## 4. Sintomas detalhados no Cursor

1. Input do Cursor claramente com caret (“Send follow-up”).
2. Usuário segura `⇧ Tab`, fala, waveform **se move**.
3. Ao soltar, overlay some / mostra sucesso ou segue o fluxo de inserção.
4. **Nenhum texto** entra no input do Cursor.
5. Mesmo fluxo no **Notas** cola a frase de teste corretamente.
6. Opção de menu “Inserir texto de teste (3s)” já funcionou no Cursor em pelo menos um teste (sem gravar / sem ⇧ Tab).

Isso sugere que o problema não é “Acessibilidade negada” nem “clipboard quebrado”, e sim uma combinação de:

- **timing do atalho ⇧ Tab** (modificadores / foco)
- **Electron não receber CGEvent** da mesma forma que apps Cocoa
- **foco/caret perdido** entre stop da gravação e o paste
- **AX “sucesso falso”** em nós não-editáveis (mitigado, mas histórico relevante)

---

## 5. Soluções / hipóteses já testadas (e resultado)

### 5.1 Áudio (contexto — resolvido, não é a falha atual)

| Tentativa | Resultado |
|---|---|
| `AVAudioEngine` + tap | Arquivos silenciosos / waveform parada |
| `AVAudioRecorder` | Arquivos “válidos” mas silenciosos |
| Entitlement errado `com.apple.security.device.audio.input` (ponto) + App Sandbox | Sessão “ok”, **0 buffers**, `.m4a` 0 bytes |
| Entitlement correto `audio-input` + sandbox off + `AVCaptureSession` + PCM 16 kHz → AAC | **Funcionou** (Fifine, pico ~0.3–0.4, arquivos ~15–26 KB) |
| Usuário rodando build antigo do Xcode DerivedData (sandbox antigo) | Regressão falsa de áudio; misturava sintomas |

### 5.2 Acessibilidade / TCC (contexto — resolvido o suficiente)

| Tentativa | Resultado |
|---|---|
| Toggle ON em Ajustes mas status “pendente” | Comum com **ad-hoc**: toggle de outra CDHash/cópia |
| Só “Reiniciar app” | **Não resolve** se a entrada TCC é de outra assinatura |
| `tccutil reset Accessibility dev.arley.santana.VoiceIA` | Necessário |
| Remover VoiceIA da lista com botão **−** (não só desligar toggle) | Necessário |
| Instalar em `/Applications/VoiceIA.app` | Melhor estabilidade de TCC entre testes |
| Rebuild frequente sem reautorizar | Quebra de novo (`AXIsProcessTrusted == false`) |

### 5.3 Descoberta de foco (parcial)

| Tentativa | Resultado |
|---|---|
| Só `kAXFocusedUIElementAttribute` no system-wide | Falha frequente no Cursor (“nenhum campo em foco”) mesmo com caret visível |
| Cascata: system-wide → focused application → UI element → app da frente | Melhor; no Electron muitas vezes só há **AXApplication** |
| Tratar falha de foco como hard-fail antes de gravar | Ruim — bloqueava gravação; trocado por best-effort |
| Retry de foco ao vivo na inserção | Ajuda no teste de 3s; no pós-⇧Tab ainda falha no Cursor |

### 5.4 Inserção via Accessibility API

| Tentativa | Resultado |
|---|---|
| `AXUIElementSetAttributeValue(..., kAXSelectedTextAttribute, text)` | Funciona em Notas/TextEdit; no Cursor costuma **não** afetar o contenteditable |
| Reescrever `kAXValueAttribute` + `kAXSelectedTextRangeAttribute` | Idem — bom em nativos |
| Confiar em `SetAttribute == success` em `AXWebArea` / `AXGroup` / `AXApplication` | **Falso positivo** — API retorna success, UI não muda |
| Restringir AX direto a roles `AXTextField` / `AXTextArea` / `AXComboBox` / `AXSearchField` | Evita falso sucesso; no Cursor cai no fallback clipboard (desejado) |

### 5.5 Clipboard + ⌘V

| Tentativa | Resultado |
|---|---|
| `NSPasteboard` + `CGEvent` ⌘V em `.cgSessionEventTap` | Notas OK; Cursor **não** |
| Não reativar app se já é frontmost (evitar blur no Electron) | Não resolveu o pós-gravação no Cursor |
| Sempre `activate()` o PID alvo antes do paste | Ainda falha no Cursor no fluxo ⇧ Tab |
| Esperar soltar modificadores (`CGEventSource.flagsState`) antes do ⌘V | Hipótese forte: ⇧ ainda baixo → vira ⌘⇧V; mitiga, mas Cursor pós-gravação **ainda falha** |
| Delay 120–250 ms após release do hotkey | Não suficiente sozinho |
| `CGEvent` em `.cghidEventTap` + source `.hidSystemState` | Implementado; Cursor pós-⇧ Tab ainda falha nos testes do usuário |
| Fallback `NSAppleScript` / System Events `keystroke "v" using command down` | Implementado; usuário relatou que Cursor **ainda** não recebe o texto no fluxo de gravação |
| Clique AX no centro do elemento focado (conversão coords AX→Quartz) antes do paste | Implementado; sem confirmação de sucesso no Cursor |
| Esconder HUD (`recordingState = .idle`) antes de colar | Implementado para não roubar foco; Cursor ainda falha |

### 5.6 Diferença teste 3s vs fluxo ⇧ Tab

| Caminho | Comportamento |
|---|---|
| Menu “Inserir texto de teste (3s)” → sleep → `insert(text:)` com retry + frontmost | Já funcionou no Cursor |
| `⇧ Tab` → grava → `insert(text:into: captured)` com PID capturado no key-down | Waveform OK; **Cursor não cola**; Notas cola |

Diferenças suspeitas entre os caminhos:

1. **Modificador Shift** ainda interagindo com o paste no release do hotkey Carbon.  
2. **Foco/caret do Cursor** muda ou “esfria” durante a gravação / overlay.  
3. Elemento AX **capturado no key-down** fica stale (só app-level) e o clique/paste não reacende o contenteditable.  
4. Carbon `RegisterEventHotKey` para Tab pode ter efeitos colaterais de foco em apps web.  
5. Overlay `orderFrontRegardless` durante `.recording` pode ter efeitos sutis no Electron mesmo sendo `nonactivatingPanel`.

---

## 6. Estado atual do código de inserção (última versão)

Estratégia em `DefaultTextInsertionService`:

1. Esperar modificadores limpos.  
2. Tentar AX só em roles de campo de texto.  
3. Clipboard snapshot → set string.  
4. `NSRunningApplication.activate()` no PID alvo.  
5. Clique opcional no frame AX do elemento.  
6. ⌘V via HID tap; se falhar, session tap; se falhar, System Events.  
7. Restaurar clipboard.

Em `AppState.insertStage56TestText()`:

1. `recordingState = .idle` (esconde overlay).  
2. Sleep ~150 ms.  
3. `insert(into: captured)` ou `insert(text:)`.  
4. `.success` / `.error`.

---

## 7. Hipóteses ainda NÃO refutadas (para o próximo modelo)

1. **Cursor exige foco de teclado no `webContents`**, e `activate()` + paste sem um input event “confiável” (IOHID / evento sintetizado de outra forma) não chega ao renderer.  
2. **Input Monitoring** (além de Accessibility) pode ser necessário para CGEvent HID em alguns builds do macOS — não foi pedido/verificado explicitamente em Privacy → Input Monitoring.  
3. O chat do Cursor pode estar em **processo filho** (PID do helper ≠ PID capturado do app principal); paste vai para o processo errado.  
4. Precisa **reencontrar o focused UI element imediatamente antes do paste**, ignorando o snapshot stale do key-down, *e* clicar coordenadas do `AXTextArea`/`AXTextField` real dentro da árvore (walk da hierarchy), não o `AXApplication`.  
5. Usar **CGEvent keyboard com unicode string** / `CGEventKeyboardSetUnicodeString` em vez de keycode V.  
6. Usar **AppleScript `keystroke` do texto direto** (sem clipboard) — frágil com Unicode, mas útil como probe.  
7. Integrar **`AXUIElementPostKeyboardEvent`** (legado) no elemento focado.  
8. Trocar atalho para algo que não seja Tab (ex.: `⌥ Space` do plano original) para isolar side-effects do Tab.  
9. Verificar com Accessibility Inspector o role/hierarchy exatos do “Send follow-up” no Cursor.  
10. Confirmar se o paste “funciona” mas vai para **outro campo** do Cursor (composer oculto, find bar, etc.).

---

## 8. Como reproduzir

1. Abrir `/Applications/VoiceIA.app` (garantir Acessibilidade **autorizada** no menu).  
2. Abrir Cursor, focar o input do chat.  
3. Segurar `⇧ Tab`, falar 2–3 s (waveform deve mexer).  
4. Soltar.  
5. **Esperado hoje:** colar `Olá, este é um teste do VoiceIA.`  
6. **Observado:** nada no input do Cursor.  
7. Repetir no Notas com um documento aberto e caret no corpo → **funciona**.

Controle positivo sem gravação:

- Menu VoiceIA → “Inserir texto de teste (3s)” → clicar no input do Cursor dentro da janela → observar se cola.

---

## 9. Critério de sucesso desejado

1. Com Acessibilidade OK, `⇧ Tab` no input do Cursor cola o texto de teste de forma confiável (≥ 9/10).  
2. Continuar funcionando no Notas / TextEdit / Safari.  
3. Não corromper o clipboard do usuário (snapshot/restore já existe).  
4. Depois (Etapa 7): trocar o texto fixo pela string da OpenAI sem mudar o mecanismo de inserção.

---

## 10. Restrições / notas para quem for continuar

- **Não reintroduzir App Sandbox** sem plano para Accessibility cross-process + inserção.  
- Assinatura ad-hoc invalida TCC a cada rebuild — documentar / preferir Apple Development cert quando houver identity.  
- Não apagar arquivos de gravação automaticamente enquanto depurar.  
- Comentários/KDoc do projeto devem permanecer em **português**.  
- OpenAI / Keychain ainda **não** estão implementados; não misturar com este bug.  
- Evitar assumir que `AXSetAttribute` success == UI atualizada em Electron.

---

## 11. Logs úteis

Subsystem: `dev.arley.santana.VoiceIA`  
Categories: `audio`, `accessibility`, `insertion`

```bash
/usr/bin/log stream --predicate 'subsystem == "dev.arley.santana.VoiceIA"' --level info --style compact
```

Gravações (build sem sandbox):

`~/Library/Application Support/VoiceIA/Recordings/`

---

## 12. Pedido explícito ao próximo modelo

Focar **somente** em fazer a inserção pós-`⇧ Tab` funcionar no **Cursor** com a mesma confiabilidade do Notas, reutilizando o texto de teste.  

Preferir mudanças mínimas em `DefaultTextInsertionService` / `AppState` / hotkey.  

Validar com experimento A/B:

- A: inserção sem gravar (já ok às vezes)  
- B: inserção após gravação curta no Cursor (falha)  
- C: Notas após gravação (ok)

Instrumentar logs do PID alvo, role AX, método de paste usado (AX / HID / session / System Events) e se `activate()` / click ocorreram.
