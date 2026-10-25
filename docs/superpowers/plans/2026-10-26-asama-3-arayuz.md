# Aşama 3 — Arayüz Tasarımı: Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Çentikteki ada + Liquid Glass panelle kurumsal, sade arayüz; görünümler test edilebilir ayrı hedefte; global kısayollar.

**Architecture:** Yeni `AINotepadUI` hedefi (SwiftUI; `AINotepadCore`'a bağlı) saf sunum fonksiyonları, tasarım ölçüleri ve `LiveViewState` ile beslenen görünümleri içerir. Uygulama hedefi pencereleri (`NSPanel`) kurar, `AppModel`'den `LiveViewState` üretir ve kısayolları bağlar.

**Tech Stack:** SwiftUI (macOS 26 `glassEffect`), AppKit `NSPanel`/`NSScreen`, Carbon `RegisterEventHotKey`, Swift Testing, `ImageRenderer`.

**Spec:** `docs/superpowers/specs/2026-10-25-ai-notepad-design.md` (§4.3 Görsel tasarım; §4.1 UI)

## Global Constraints

- Swift 6 strict; Türkçe yorum/metin; varsayılan parametre yok; saf fonksiyon; sınıf yalnızca bağlayıcı/pencere denetleyicisi.
- Değerler §4.3'ten aynen: boşluk 4/8/12/16/24; yarıçap panel 22, çip 10; metin 14 pt, etiket 11 pt semibold büyük harf (izleme 0,6), durum 12 pt medium; geçici %55; "Sen" `#3B5BDB`; kişi paleti `#0CA678 #F08C00 #D6336C #7048E8 #1098AD #5C940D`; ada kanadı 120 pt, açılma +64 pt, hap çentiksiz ekranda menü çubuğunun 8 pt altı.
- Görünümler `AppModel` görmez; yalnızca `LiveViewState` + kapanışlar.
- Snapshot testleri `AINOTEPAD_SNAPSHOTS=1` ile, PNG'ler `/tmp/ainotepad-snapshots/`; doğrulama: dosya üretildi + boyut > 0 ve geliştirici görselleri inceler.

## Review Focus

1. **Harici monitör / çentiksiz ekran / ekran değişimi:** ada doğru yerde (çentiksiz: hap) → Task 2 `pillWithoutNotch`, `notchIslandCentersOnNotch`.
2. **Çok uzun cümle / çok kişi (7+):** ada metni taşmaz, renkler döner → Task 1 `personColorWraps`, `latestSentenceTruncatesFromStart`.
3. **Kayıt yokken ada görünmemeli; kayıt bitince gizlenmeli** → Task 1 `islandHiddenWhenNotRecording`.
4. **Kısayol başka uygulamada kayıtlıysa:** açık hata (sessiz değil) → Task 6 kayıt hatası menüde gösterilir.
5. **Yankı süzülmüş metin hem panelde hem adada aynı olmalı** → Task 1 `viewStateUsesEchoFilteredTranscript`.

---

### Task 1: `AINotepadUI` hedefi, tasarım ölçüleri ve sunum durumu

**Files:** Modify `Packages/AINotepadCore/Package.swift` (ürün + hedef `AINotepadUI`, test hedefi `AINotepadUITests`); Create `Sources/AINotepadUI/DesignTokens.swift`, `Sources/AINotepadUI/LiveViewState.swift`, `Tests/AINotepadUITests/PresentationTests.swift`.

**Interfaces (Produces):**
```swift
public enum DesignTokens { spacing (xs 4, s 8, m 12, l 16, xl 24), panelRadius 22, chipRadius 10,
    meColor: Color, personPalette: [Color], partialOpacity 0.55 }
public func personColor(person: Int) -> Color          // 1-tabanlı; 7 → palet[0]
public struct LiveViewState: Equatable, Sendable {
    public let isRecording: Bool; public let startedAt: Date?; public let statusText: String
    public let languageText: String; public let blocks: [SpeakerBlock]; public let errors: [String]
    public let latestOthersSentence: String?; public let isIslandVisible: Bool }
public func makeLiveViewState(transcript: [LiveSegment], isRecording: Bool, startedAt: Date?,
    statusText: String, languageText: String, errors: [String]) -> LiveViewState
public func truncateFromStart(text: String, maxCharacters: Int) -> String   // "…" + son N karakter
```
`makeLiveViewState`: `suppressEchoes` → `groupBySpeaker`; `latestOthersSentence` = yankısız transkriptteki son metinli "Diğerleri" bölümü, 140 karaktere `truncateFromStart`; `errors` son 3; `isIslandVisible == isRecording`.

- [ ] Testler: `personColorWraps` (7 == 1, 2 != 1), `latestSentenceTruncatesFromStart` (200 karakter → 141, "…" ile başlar, orijinalin sonuyla biter), `islandHiddenWhenNotRecording`, `viewStateUsesEchoFilteredTranscript` (yankı "Sen" bloğu yok), `errorsKeepLastThree`. RED → uygula → GREEN. Commit.

### Task 2: Ada geometrisi (saf)

**Files:** Create `Sources/AINotepadUI/IslandGeometry.swift`, `Tests/AINotepadUITests/IslandGeometryTests.swift`.

```swift
public struct ScreenGeometry: Sendable, Equatable { public let frame: CGRect; public let visibleFrame: CGRect
    public let safeAreaTop: CGFloat; public let auxiliaryTopLeft: CGRect; public let auxiliaryTopRight: CGRect }
public struct IslandLayout: Sendable, Equatable { public let frame: CGRect; public let hasNotch: Bool; public let collapsedHeight: CGFloat }
public func islandLayout(screen: ScreenGeometry, wing: CGFloat, expansion: CGFloat, pillHeight: CGFloat, pillWidth: CGFloat, pillGap: CGFloat) -> IslandLayout
```
Çentik: `safeAreaTop > 0` ve iki yardımcı alan boş değil → çentik x aralığı = sol alanın maxX…sağ alanın minX; çerçeve x = çentikMinX − wing, genişlik = çentik + 2·wing, üst = frame.maxY, yükseklik = safeAreaTop + expansion (pencere açılmaya yer bırakır; kapalı içerik üstte `collapsedHeight = safeAreaTop`). Çentiksiz: genişlik `pillWidth`, ortada, üst = visibleFrame.maxY − pillGap, yükseklik pillHeight + expansion, `collapsedHeight = pillHeight`.
- [ ] Testler: `notchIslandCentersOnNotch` (1512×982 ekran, safeTop 32, sol alan 0…660, sağ 852…1512 → x 540, genişlik 432, maxY 982, yükseklik 96), `pillWithoutNotch` (1920×1080, visible maxY 1055 → genişlik 360, ortada, maxY 1047). RED → GREEN. Commit.

### Task 3: Cam panel görünümü + snapshot altyapısı

**Files:** Create `Sources/AINotepadUI/TranscriptPanel.swift`, `Tests/AINotepadUITests/SnapshotTests.swift`.
```swift
public struct TranscriptPanel: View { public init(state: LiveViewState, onCopyAll: @escaping @MainActor () -> Void,
    onHide: @escaping @MainActor () -> Void) }
```
§4.3 düzeni; gövde `ScrollViewReader` ile sona kayar (transkript değişince); blok: renk noktası (Sen → meColor, kişi → personColor, Diğerleri → secondary) + etiket + metin (geçici kısım %55); bloğa sağ tık "Kopyala"; kök `.glassEffect(.regular, in: .rect(cornerRadius: DesignTokens.panelRadius))`.
- [ ] Snapshot testi (`.enabled(if: AINOTEPAD_SNAPSHOTS=1)`, `@MainActor`): örnek durum (Sen + Konuşmacı 1/2 + geçici + 1 hata) → `ImageRenderer` 380×520 @2x → `/tmp/ainotepad-snapshots/panel.png`; dosya var ve > 10 KB. Çalıştır, PNG'yi incele, gerekirse düzelt. Commit.

### Task 4: Ada görünümü + snapshot

**Files:** Create `Sources/AINotepadUI/IslandView.swift`; Modify `SnapshotTests.swift`.
```swift
public struct IslandView: View { public init(state: LiveViewState, layout: IslandLayout, isExpanded: Bool,
    onTap: @escaping @MainActor () -> Void) }
```
Kapalı: üst `collapsedHeight` şeridinde sol kanat (kırmızı nokta + süre), sağ kanat (dil); çentik bölgesi boş siyah. Açık: altta 2 satır son cümle. Siyah şekil: alt köşeleri 18 pt yuvarlak. Açılma `.spring(response: 0.35, dampingFraction: 0.82)`.
- [ ] Snapshot: kapalı ve açık (`island-collapsed.png`, `island-expanded.png`), çentikli düzenle. İncele. Commit.

### Task 5: Uygulama entegrasyonu

**Files:** Create `App/IslandController.swift`; Modify `App/LivePanel.swift` (kenarlıksız cam panel), `App/AppModel.swift` (`viewState: LiveViewState` hesaplanan), `App/AINotepadApp.swift` (menü SF Symbols, "Paneli göster/gizle"); Delete `App/LiveTranscriptView.swift`; `project.yml` paketten `AINotepadUI` ürününü ekle.
- Panel: `[.borderless, .nonactivatingPanel, .resizable]`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = true`, `isMovableByWindowBackground = true`, seviye `.floating`, `sharingType` ayarı korunur.
- Ada: `NSPanel` `[.borderless, .nonactivatingPanel]`, seviye `.statusBar + 1`, `canJoinAllSpaces/stationary/fullScreenAuxiliary`, çerçeve `islandLayout(...)` (ekran `NSScreen.main`, wing 120, expansion 64, hap 360×32, gap 8); `NSScreen` değişince (`didChangeScreenParametersNotification`) yeniden konumlanır; fare üstüne gelince açılır (`onHover`), tıklama paneli aç/kapa; kayıt yokken `orderOut`.
- [ ] Derle (uyarısız); uygulamayı aç, `screencapture` ile menü çubuğu bölgesini al, adanın görünmediğini (kayıt yok) doğrula. Tüm testler. Commit.

### Task 6: Global kısayollar

**Files:** Create `App/HotKeys.swift`; Modify `App/AINotepadApp.swift`.
```swift
@MainActor final class HotKeyCenter { init(); func register(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) throws }
enum HotKeyError: Error, Equatable { case registrationFailed(keyCode: UInt32, status: Int32) }
```
`InstallEventHandler(GetApplicationEventTarget(), …kEventHotKeyPressed…)` bir kez; `RegisterEventHotKey` ⌃⌥R (`kVK_ANSI_R`, `controlKey|optionKey`) ve ⌃⌥Space (`kVK_Space`). Kayıt hatası menüde kırmızı metin.
- [ ] Derle; uygulama açıkken `osascript` ile kısayol gönderilemiyorsa (izin) elle kabul listesine ekle. Commit.

### Task 7: Kabul listesi

- [ ] `docs/superpowers/acceptance-checklist.md`'ye "Arayüz (aşama 3)" maddeleri: ada çentikte/harici monitörde hap, hover açılma, tıklama paneli, panel taşıma/boyutlandırma, cam görünüm açık/koyu arka planda, kısayollar, ekran değişimi.
