# Aşama 1 — Çekirdek: Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zoom/Teams'teki Fince veya İngilizce konuşmayı canlı olarak yazıya döken, "Sen" ve "Diğerleri"ni ayıran ve sesi diske yazan bir menü çubuğu uygulaması.

**Architecture:** Tüm mantık yerel Swift paketi `AINotepadCore`'da; Xcode uygulaması (`AINotepad`, XcodeGen ile üretilir) yalnızca UI ve yakalama başlatma/durdurma içerir. Ses → saf fonksiyonlu bölümleyici → tek seri işçi üzerinden WhisperKit → olay akışı (`AsyncStream<LiveSessionEvent>`) → saf reducer → SwiftUI panel.

**Tech Stack:** Swift 6.2+ (strict concurrency), SwiftUI + AppKit `NSPanel`, WhisperKit 1.1.1 (`https://github.com/argmaxinc/WhisperKit.git`, MIT), AVFoundation, Core Audio process tap, Swift Testing, XcodeGen 2.45.

**Spec:** `docs/superpowers/specs/2026-10-25-ai-notepad-design.md` (bu plan §8'deki Aşama 1'i uygular)

## Global Constraints

- Deployment target: macOS 26.0, yalnızca Apple Silicon. Paket: `platforms: [.macOS(.v26)]`.
- Swift 6 dil modu, `SWIFT_STRICT_CONCURRENCY = complete`.
- Kod yorumları **yalnızca Türkçe**. UI metinleri Türkçe.
- Veri `struct`/`enum`, mantık saf fonksiyon; `class`/`actor` yalnızca dış sistem bağlayıcılarında (ses cihazları, WhisperKit, dosya yazma).
- Kendi kodumuzda varsayılan parametre değeri yok; tüm parametreler açık. Flag parametresiyle davranış değiştiren fonksiyon yok.
- Hatalar tipli ve bağlam içerir; sessiz yedek yok. Loglama `os.Logger`, dinamik değerler mesaja gömülmez (`privacy` ile ayrı alan).
- Ses formatı (iç): 16 kHz, mono, `Float32`. Diskte: 16 kHz mono Int16 `.caf`, `me.caf` ve `others.caf`.
- Canlı model: `large-v3-v20240930_turbo_632MB`. Modeller: `~/Library/Application Support/AINotepad/Models`.
- Oturum kayıtları: `~/Library/Application Support/AINotepad/Sessions/<yyyyMMdd-HHmmss>/`.
- Bölümleme: sessizlikte kes, bölüm en fazla 15 sn. Dil kilidi: "Otomatik" modda 30 sn.
- Bundle ID: `com.senoldogan.AINotepad`. `DEVELOPMENT_TEAM` repoya girmez (`Config/Local.xcconfig`, gitignore'da).
- Model gerektiren testler yalnızca `AINOTEPAD_MODEL_TESTS=1` ile çalışır.

## Review Focus

1. **Kulaklıksız kullanım (hoparlörden dinleme):** mikrofon diğerlerinin sesini de duyar, aynı cümle hem "Sen" hem "Diğerleri" olarak görünür. Beklenen: Aşama 1'de en azından ölçülür ve kullanıcıya raporlanır → Task 9, adım 4.
2. **Sessizlik, gürültü, müzik:** Whisper sessizlikte uydurma metin üretir ("Kiitos katsomisesta"). Beklenen: hiç bölüm ya da boş metin → Task 2 `silenceProducesNoSegments`, Task 4 `transcribeReturnsEmptyForNoise`.
3. **Uzun kesintisiz konuşma (ders anlatımı):** 15 sn sınırında kesilen konuşmada örnek kaybı olmamalı. Beklenen: ardışık bölümler bitişik → Task 2 `longSpeechSplitsContiguously`.
4. **Toplantı ortasında çıkış cihazı değişimi (AirPods takma/çıkarma):** sistem sesi yakalaması sessizce durmamalı. Beklenen: otomatik yeniden bağlanma veya açık hata → Task 6, adım 3 + Task 9, adım 5.
5. **İzin reddi (mikrofon veya sistem sesi):** Beklenen: panelde Türkçe, açık hata; diğer akış çalışmaya devam eder → Task 6 hata tipleri + Task 9, adım 6.

---

## Dosya yapısı

```
project.yml                                  XcodeGen tanımı
Config/Signing.xcconfig                      #include? "Local.xcconfig"
Config/Local.xcconfig.example                DEVELOPMENT_TEAM şablonu
AGENTS.md                                    Repo komutları (build/test)
scripts/make-test-fixtures.sh                Test seslerini `say` ile üretir
App/
  AINotepadApp.swift                         @main, MenuBarExtra
  AppModel.swift                             @MainActor @Observable uygulama durumu
  LivePanel.swift                            NSPanel oluşturma
  LiveTranscriptView.swift                   SwiftUI transkript görünümü
Packages/AINotepadCore/
  Package.swift
  Sources/AINotepadCore/
    Model/TranscriptTypes.swift              Speaker, MeetingLanguage, LanguageMode, SegmentID, LiveSegment
    Segmentation/SpeechSegmenter.swift       Saf bölümleyici
    Language/LanguageSelection.swift         Saf dil seçimi ve kilidi
    Transcription/TranscriptionEngine.swift  Protokol + TranscriptionError
    Transcription/WhisperKitEngine.swift     actor
    Audio/AudioResampler.swift               AVAudioConverter sarmalayıcı
    Audio/CafRecorder.swift                  .caf yazıcı
    Audio/AudioCaptureError.swift
    Audio/MicrophoneCapture.swift
    Audio/SystemAudioCapture.swift           Core Audio process tap
    Session/LiveSession.swift                runLiveSession(...)
    Session/TranscriptReducer.swift          Saf reducer
    Support/AppPaths.swift                   Application Support yolları
  Tests/AINotepadCoreTests/
    Fixtures/fi-meeting.wav, en-meeting.wav
    FixtureLoader.swift
    SpeechSegmenterTests.swift
    LanguageSelectionTests.swift
    WhisperKitEngineTests.swift
    AudioFileTests.swift
    TranscriptReducerTests.swift
    LiveSessionTests.swift
```

---

### Task 1: Proje iskeleti

**Files:**
- Create: `Packages/AINotepadCore/Package.swift`, `Packages/AINotepadCore/Sources/AINotepadCore/Support/AppPaths.swift`, `project.yml`, `Config/Signing.xcconfig`, `Config/Local.xcconfig.example`, `Config/Local.xcconfig` (gitignore'da), `App/AINotepadApp.swift`, `AGENTS.md`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `AppPaths.applicationSupport() throws -> URL`, `AppPaths.modelsDirectory() throws -> URL`, `AppPaths.newSessionDirectory(startedAt: Date) throws -> URL` (`enum AppPaths` namespace'i; dizinleri oluşturur, oluşturamazsa hata fırlatır).

- [ ] **Step 1: `Package.swift`**
  `swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]`, ürün `AINotepadCore`, bağımlılık `.package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1")`, hedef bağımlılığı `.product(name: "WhisperKit", package: "WhisperKit")`, test hedefi `AINotepadCoreTests` ve `resources: [.copy("Fixtures")]` (klasör Task 4'te dolar; şimdilik `.gitkeep`).

- [ ] **Step 2: `AppPaths.swift`** — yukarıdaki üç fonksiyon. Oturum klasör adı `yyyyMMdd-HHmmss` (`en_US_POSIX`, yerel saat dilimi).

- [ ] **Step 3: Doğrula** — Run: `swift build --package-path Packages/AINotepadCore` → Expected: `Build complete!` (WhisperKit indirilir).

- [ ] **Step 4: İmza yapılandırması**
  Takım kimliğini öğren: `security find-certificate -c "Apple Development: SENOL DOGAN" -p | openssl x509 -noout -subject` → `OU=` değeri. `Config/Local.xcconfig`: `DEVELOPMENT_TEAM = <OU>`. `Config/Local.xcconfig.example`: `DEVELOPMENT_TEAM = YOUR_TEAM_ID`. `Config/Signing.xcconfig`: `CODE_SIGN_STYLE = Automatic` ve `#include? "Local.xcconfig"`. `.gitignore`'a ekle: `*.xcodeproj`, `Config/Local.xcconfig`.

- [ ] **Step 5: `project.yml`**
  Proje `AINotepad`, `deploymentTarget: macOS: "26.0"`, yerel paket `AINotepadCore: path: Packages/AINotepadCore`. Hedef `AINotepad` (`type: application`, `platform: macOS`, `sources: [App]`, bağımlılık `package: AINotepadCore`), `configFiles` Debug/Release → `Config/Signing.xcconfig`. Ayarlar: `PRODUCT_BUNDLE_IDENTIFIER: com.senoldogan.AINotepad`, `SWIFT_VERSION: "6.0"`, `SWIFT_STRICT_CONCURRENCY: complete`, `GENERATE_INFOPLIST_FILE: YES`, `INFOPLIST_KEY_LSUIElement: YES`, `INFOPLIST_KEY_NSMicrophoneUsageDescription: "AI-Notepad toplantıda söylediklerini yazıya dökmek için mikrofonu kullanır."`. `NSAudioCaptureUsageDescription` için `INFOPLIST_KEY_` desteği yoksa `info.properties` ile ekle: `"AI-Notepad toplantıdaki diğer katılımcıların sesini yazıya dökmek için sistem sesini dinler."`.

- [ ] **Step 6: `AINotepadApp.swift`** — `@main struct AINotepadApp: App`, `MenuBarExtra("AI-Notepad", systemImage: "waveform")` içinde yalnızca "Çık" (`NSApplication.shared.terminate(nil)`).

- [ ] **Step 7: Doğrula** — Run: `xcodegen generate && xcodebuild -project AINotepad.xcodeproj -scheme AINotepad -configuration Debug build -quiet` → Expected: çıkış kodu 0. Uygulamayı aç (`open` ile build çıktısı), menü çubuğunda dalga ikonunun göründüğünü kontrol et.

- [ ] **Step 8: `AGENTS.md`** — repo komutları: `xcodegen generate`, yukarıdaki `xcodebuild` komutu, `swift test --package-path Packages/AINotepadCore`, model testleri için `AINOTEPAD_MODEL_TESTS=1 swift test --package-path Packages/AINotepadCore`. Global kurallara referans; tekrar yazma.

- [ ] **Step 9: Commit** — `git add -A && git commit -m "chore: proje iskeleti (XcodeGen + AINotepadCore paketi)"`

---

### Task 2: Temel tipler ve konuşma bölümleyici

**Files:**
- Create: `Sources/AINotepadCore/Model/TranscriptTypes.swift`, `Sources/AINotepadCore/Segmentation/SpeechSegmenter.swift`
- Test: `Tests/AINotepadCoreTests/SpeechSegmenterTests.swift`

**Interfaces:**
- Produces (`TranscriptTypes.swift`):
  ```swift
  public enum Speaker: String, Sendable, Hashable, Codable { case me, others }
  public enum MeetingLanguage: String, Sendable, Hashable, Codable { case finnish = "fi", english = "en" }
  public enum LanguageMode: Sendable, Hashable { case automatic, fixed(MeetingLanguage) }
  public struct SegmentID: Sendable, Hashable { public let speaker: Speaker; public let index: Int }
  public struct LiveSegment: Sendable, Equatable, Identifiable {
      public let id: SegmentID; public let startSec: Double; public let endSec: Double
      public let text: String; public let isFinal: Bool; public let failureMessage: String?
  }
  ```
- Produces (`SpeechSegmenter.swift`):
  ```swift
  public struct SegmenterConfig: Sendable, Equatable {
      public let sampleRate: Int; public let frameSamples: Int; public let energyThreshold: Float
      public let minSilenceSec: Double; public let maxSegmentSec: Double; public let minSpeechSec: Double
      public static let live: SegmenterConfig  // 16000, 1600, 0.01, 0.6, 15, 0.3
  }
  public struct OpenSegment: Sendable, Equatable { index: Int; startSample: Int; samples: [Float]; trailingSilenceSamples: Int }
  public struct ClosedSegment: Sendable, Equatable { index: Int; startSample: Int; samples: [Float] }
  public struct SegmenterState: Sendable, Equatable { consumedSamples: Int; nextIndex: Int; open: OpenSegment?; carry: [Float]
      public static let initial: SegmenterState }
  public struct SegmenterOutput: Sendable, Equatable { state: SegmenterState; closed: [ClosedSegment] }
  public func segmentAudio(state: SegmenterState, newSamples: [Float], config: SegmenterConfig) -> SegmenterOutput
  public func flushSegmenter(state: SegmenterState, config: SegmenterConfig) -> SegmenterOutput
  ```

- [ ] **Step 1: Failing testler** (`ton(sn)` = genliği 0.3 olan 440 Hz sinüs, `sessizlik(sn)` = sıfırlar; 16 kHz)

  ```swift
  @Test func silenceProducesNoSegments()        // 5 sn sessizlik → closed boş, state.open == nil
  @Test func speechThenSilenceClosesOneSegment() // ton(1.0)+sessizlik(1.0) → 1 bölüm, startSample 0,
                                                 // samples.count == 16000 (sondaki sessizlik kırpılır)
  @Test func shortBlipIsDropped()                // ton(0.1)+sessizlik(1.0) → 0 bölüm
  @Test func longSpeechSplitsContiguously()      // ton(20) → closed[0].samples.count == 240000,
                                                 // flush sonrası 2. bölüm startSample == 240000,
                                                 // toplam örnek == 320000
  @Test func chunkBoundariesDoNotMatter()        // ton(1)+sessizlik(1)'i 1 parça ve 37 örneklik
                                                 // parçalar halinde ver → aynı closed listesi
  @Test func flushClosesOpenSegment()            // ton(2) sonra flush → 1 bölüm, open == nil
  ```

- [ ] **Step 2: Çalıştır** — `swift test --package-path Packages/AINotepadCore --filter SpeechSegmenterTests` → FAIL (tanımsız semboller).

- [ ] **Step 3: Uygula**
  Kurallar: `carry + newSamples` `frameSamples`'lık çerçevelere bölünür, artan `carry`'de kalır. Çerçeve RMS > `energyThreshold` ise konuşma. Açık bölüm yokken konuşma çerçevesi `nextIndex` ile yeni bölüm açar (`startSample` = çerçevenin akıştaki başlangıcı); sessiz çerçeve atılır. Açık bölümde çerçeve eklenir; konuşmaysa `trailingSilenceSamples = 0`, değilse `+= frameSamples`. Kapatma: (a) `trailingSilenceSamples >= minSilenceSec * rate` → sondaki sessizlik kırpılır; kalan < `minSpeechSec * rate` ise bölüm atılır (index geri alınmaz). (b) `samples.count >= maxSegmentSec * rate` → kırpmadan kapat. `flushSegmenter` açık bölümü (a)'daki kurallarla kapatır ve `carry`'yi bırakır.

- [ ] **Step 4: Çalıştır** — aynı komut → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(core): temel tipler ve konuşma bölümleyici"`

---

### Task 3: Dil seçimi ve kilidi

**Files:**
- Create: `Sources/AINotepadCore/Language/LanguageSelection.swift`, `Sources/AINotepadCore/Transcription/TranscriptionEngine.swift` (yalnızca `TranscriptionError`; protokol Task 4'te)
- Test: `Tests/AINotepadCoreTests/LanguageSelectionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum TranscriptionError: Error, Equatable {
      case languageProbabilitiesMissing(availableCodes: [String])
      case modelLoadFailed(model: String, reason: String)
      case transcriptionFailed(sampleCount: Int, language: String, reason: String)
  }
  public struct LanguageVotes: Sendable, Equatable { public let finnish: Double; public let english: Double
      public static let empty: LanguageVotes }
  public func pickLanguage(logProbs: [String: Float]) throws -> MeetingLanguage
  public func addVote(votes: LanguageVotes, logProbs: [String: Float]) throws -> LanguageVotes
  public func lockedLanguage(votes: LanguageVotes, elapsedSec: Double, lockAfterSec: Double) -> MeetingLanguage?
  public func leadingLanguage(votes: LanguageVotes) -> MeetingLanguage?
  ```
  `logProbs` WhisperKit `detectLangauge` çıktısıdır (anahtar: `"fi"`, `"en"`, …; değer: log olasılık).

- [ ] **Step 1: Failing testler**
  ```swift
  @Test func picksHigherOfFinnishAndEnglish()   // ["fi": -0.2, "en": -2.0] → .finnish
  @Test func ignoresOtherLanguages()            // ["et": -0.1, "fi": -1.0, "en": -3.0] → .finnish
  @Test func missingCodesThrow()                // ["et": -0.1] → throws .languageProbabilitiesMissing(availableCodes: ["et"])
  @Test func votesAccumulateAsProbabilities()   // addVote(.empty, ["fi": log(0.8), "en": log(0.1)])
                                                // → finnish ≈ 0.8, english ≈ 0.1 (±1e-6)
  @Test func noLockBeforeThreshold()            // votes fi>en, elapsed 29.9, lockAfter 30 → nil
  @Test func locksToMajorityAfterThreshold()    // fi 1.5, en 0.4, elapsed 30 → .finnish
  @Test func noLockWithoutVotes()               // .empty, elapsed 100 → nil
  @Test func leadingIsNilWhenEmpty()            // leadingLanguage(.empty) → nil
  ```
- [ ] **Step 2: Çalıştır** — `--filter LanguageSelectionTests` → FAIL.
- [ ] **Step 3: Uygula** — eşitlikte `.finnish` (kullanıcının ana toplantı dili). `availableCodes` sıralı.
- [ ] **Step 4: Çalıştır** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(core): otomatik dil seçimi ve 30 sn kilit"`

---

### Task 4: Test sesleri ve WhisperKitEngine

**Files:**
- Create: `scripts/make-test-fixtures.sh`, `Tests/AINotepadCoreTests/Fixtures/fi-meeting.wav`, `.../en-meeting.wav`, `Tests/AINotepadCoreTests/FixtureLoader.swift`, `Sources/AINotepadCore/Transcription/WhisperKitEngine.swift`
- Modify: `Sources/AINotepadCore/Transcription/TranscriptionEngine.swift`
- Test: `Tests/AINotepadCoreTests/WhisperKitEngineTests.swift`

**Interfaces:**
- Consumes: `MeetingLanguage`, `TranscriptionError`, `AppPaths.modelsDirectory()`.
- Produces:
  ```swift
  public protocol TranscriptionEngine: Sendable {
      func detectLanguage(samples: [Float]) async throws -> [String: Float]
      func transcribe(samples: [Float], language: MeetingLanguage) async throws -> String
  }
  public let liveWhisperModel: String = "large-v3-v20240930_turbo_632MB"
  public let noSpeechProbabilityLimit: Float = 0.6
  public actor WhisperKitEngine: TranscriptionEngine {
      public static func load(modelName: String, modelsDirectory: URL) async throws -> WhisperKitEngine
  }
  // Test hedefi:
  func loadFixture(name: String) throws -> [Float]   // Fixtures/<name>.wav → 16 kHz mono Float
  ```

- [ ] **Step 1: Fixture betiği** — `scripts/make-test-fixtures.sh` iki dosya üretir (`say -o tmp.aiff` → `afconvert -f WAVE -d LEI16@16000 -c 1`):
  - `fi-meeting.wav`, ses `Satu`: `"Hyvää huomenta kaikille. [[slnc 900]] Seuraavalla viikolla meidän pitää palauttaa raportti. [[slnc 900]] Kuka voisi ottaa vastuun esityksestä?"`
  - `en-meeting.wav`, ses `Samantha`: `"Good morning everyone. [[slnc 900]] Next week we need to submit the report. [[slnc 900]] Who could take responsibility for the presentation?"`
  Çalıştır, iki `.wav`'ı commit'e ekle (sesler makineye göre değişebildiği için dosyalar repoda tutulur).

- [ ] **Step 2: Failing testler** — suite `.enabled(if: ProcessInfo.processInfo.environment["AINOTEPAD_MODEL_TESTS"] == "1")`, motor suite başında bir kez yüklenir.
  ```swift
  @Test func detectsFinnish()   // pickLanguage(detectLanguage(fi)) == .finnish
  @Test func detectsEnglish()   // pickLanguage(detectLanguage(en)) == .english
  @Test func transcribesFinnishKeywords()  // transcribe(fi, .finnish).lowercased() içerir "raportti" ve "esitykse"
  @Test func transcribesEnglishKeywords()  // transcribe(en, .english).lowercased() içerir "report" ve "presentation"
  @Test func transcribeReturnsEmptyForNoise() // 3 sn, genlik 0.005 sabit tohumlu beyaz gürültü → ""
  ```
- [ ] **Step 3: Çalıştır** — `AINOTEPAD_MODEL_TESTS=1 swift test --package-path Packages/AINotepadCore --filter WhisperKitEngineTests` → FAIL (derlenmez).

- [ ] **Step 4: Uygula**
  - `load`: `WhisperKitConfig(model: modelName, downloadBase: modelsDirectory, verbose: false, logLevel: .error, prewarm: true, load: true, download: true)` ile `WhisperKit(config)`; hata → `.modelLoadFailed`.
  - `detectLanguage`: `whisperKit.detectLangauge(audioArray:)` (kütüphanedeki yazım hatası gerçek API adıdır) → `langProbs`.
  - `transcribe`: `DecodingOptions(task: .transcribe, language: language.rawValue, detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: true, noSpeechThreshold: noSpeechProbabilityLimit)` ile `transcribe(audioArray:decodeOptions:)`. Sonuç bölümlerinden `noSpeechProb <= noSpeechProbabilityLimit` olanların metni birleştirilir ve kırpılır. Hata → `.transcriptionFailed`.
  - Doküman yorumu: actor yeniden girişlidir; çağıran taraf çağrıları sıraya koymalıdır (Task 7'deki tek işçi).

- [ ] **Step 5: Çalıştır** — Step 3'teki komut → PASS (ilk çalıştırmada ~630 MB model iner). Gürültü testi geçmezse eşiği değil, `noSpeechProb` filtresinin uygulandığını doğrula; eşiği değiştirmek tasarım kararıdır, kullanıcıya sor.
- [ ] **Step 6: Commit** — `git commit -m "feat(core): WhisperKitEngine ve gerçek ses fixture'ları"`

---

### Task 5: Ses dönüştürme ve .caf kaydı

**Files:**
- Create: `Sources/AINotepadCore/Audio/AudioResampler.swift`, `Sources/AINotepadCore/Audio/CafRecorder.swift`, `Sources/AINotepadCore/Audio/AudioCaptureError.swift`
- Test: `Tests/AINotepadCoreTests/AudioFileTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum AudioCaptureError: Error, Equatable {
      case microphonePermissionDenied
      case systemAudioPermissionDenied
      case converterCreationFailed(inputDescription: String)
      case conversionFailed(reason: String)
      case coreAudio(operation: String, status: Int32)
      case recorderFailed(path: String, reason: String)
  }
  public final class AudioResampler {          // giriş formatı → 16 kHz mono Float32
      public init(inputFormat: AVAudioFormat) throws
      public func convert(buffer: AVAudioPCMBuffer) throws -> [Float]
  }
  public final class CafRecorder {             // 16 kHz mono Int16 .caf
      public init(fileURL: URL) throws
      public func append(samples: [Float]) throws
      public func close()
  }
  ```

- [ ] **Step 1: Failing testler**
  ```swift
  @Test func resamples48kStereoTo16kMono()  // 0.5 sn 48 kHz 2 kanal sinüs → sayım 8000 ±80
  @Test func recorderWritesReadableCaf()    // 16000 örnek yaz, close, AVAudioFile ile aç
                                            // → length == 16000, sampleRate 16000, kanal 1
  @Test func cafReadableBeforeClose()       // 16000 örnek yaz, close ÇAĞIRMADAN ikinci bir
                                            // AVAudioFile ile oku → length >= 16000 (çökme güvenliği)
  ```
- [ ] **Step 2: Çalıştır** — `--filter AudioFileTests` → FAIL.
- [ ] **Step 3: Uygula** — `AVAudioConverter` (giriş akışı parçalı geldiği için converter yeniden kullanılır, `.haveData`/`.noDataNow` ile beslenir). `CafRecorder`: `AVAudioFile(forWriting:settings:commonFormat: .pcmFormatFloat32, interleaved: false)`, ayarlar `kAudioFileCAFType`-uyumlu Int16 16 kHz mono. Hatalar `AudioCaptureError` ile, dosya yolu dahil.
- [ ] **Step 4: Çalıştır** → PASS. `cafReadableBeforeClose` geçmiyorsa yazıcıyı her `append` sonrası başlığı güncelleyecek şekilde değiştirme yolunu araştır; testi gevşetme.
- [ ] **Step 5: Commit** — `git commit -m "feat(core): ses dönüştürücü ve çökmeye dayanıklı .caf kaydı"`

---

### Task 6: Mikrofon ve sistem sesi yakalama

**Files:**
- Create: `Sources/AINotepadCore/Audio/MicrophoneCapture.swift`, `Sources/AINotepadCore/Audio/SystemAudioCapture.swift`

**Interfaces:**
- Consumes: `AudioResampler`, `AudioCaptureError`.
- Produces:
  ```swift
  @MainActor public final class MicrophoneCapture {
      public init()
      public func start() async throws -> AsyncStream<[Float]>   // 16 kHz mono parçalar
      public func stop()                                          // akışı bitirir
  }
  @MainActor public final class SystemAudioCapture {
      public init()
      public func start() async throws -> AsyncStream<[Float]>
      public func stop()
  }
  ```
  Ses geri çağrısı yalnızca kendi oluşturduğu `AudioResampler` ve `AsyncStream.Continuation`'a dokunur; ana aktöre erişmez.

- [ ] **Step 1: `MicrophoneCapture`** — `AVAudioApplication.requestRecordPermission()` reddedilirse `.microphonePermissionDenied`. `AVAudioEngine.inputNode.installTap` (giriş formatında) → resampler → `continuation.yield`. `stop` tap'i kaldırır, motoru durdurur, `continuation.finish()`.

- [ ] **Step 2: `SystemAudioCapture`** — sıra:
  1. `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`, `isPrivate = true`, `muteBehavior = .unmuted`.
  2. `AudioHardwareCreateProcessTap` → tap ID; `kAudioTapPropertyUID` ve `kAudioTapPropertyFormat` oku.
  3. Varsayılan çıkış cihazının UID'si (`kAudioHardwarePropertyDefaultOutputDevice` → `kAudioDevicePropertyDeviceUID`).
  4. `AudioHardwareCreateAggregateDevice` sözlüğü: ad `"AI-Notepad Tap"`, yeni UUID'li UID, `kAudioAggregateDeviceIsPrivateKey: true`, `kAudioAggregateDeviceMainSubDeviceKey: <çıkış UID>`, `kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: <çıkış UID>]]`, `kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: <tap UID>, kAudioSubTapDriftCompensationKey: true]]`, `kAudioAggregateDeviceTapAutoStartKey: true`.
  5. `AudioDeviceCreateIOProcIDWithBlock` → giriş `AudioBufferList`'ten tap formatında `AVAudioPCMBuffer` → resampler → yield. `AudioDeviceStart`.
  Her `OSStatus != noErr` → `.coreAudio(operation: "<çağrı adı>", status:)`. İzin reddi (ilk tap oluşturma `kAudioHardwareIllegalOperationError` vb. ya da sıfır dolu tampon) → `.systemAudioPermissionDenied`; hangi durumun reddi gösterdiğini gerçek denemeyle doğrula ve kodda Türkçe yorumla belgele. `stop`: `AudioDeviceStop`, `AudioDeviceDestroyIOProcID`, `AudioHardwareDestroyAggregateDevice`, `AudioHardwareDestroyProcessTap`, `finish()`.

- [ ] **Step 3: Çıkış cihazı değişimi (Review Focus 4)** — `kAudioHardwarePropertyDefaultOutputDevice` için `AudioObjectAddPropertyListenerBlock`; değişince toplu cihaz yeni çıkış UID'siyle yeniden kurulur, **aynı** `continuation` kullanılmaya devam eder. Yeniden kurma başarısızsa hata loglanır ve akış `finish()` ile biter (Task 7 bunu `captureFailed` olarak raporlar).

- [ ] **Step 4: Derle** — `swift build --package-path Packages/AINotepadCore` → `Build complete!` (Swift 6 strict concurrency uyarısız). Gerçek davranış Task 8–9'da uygulamada test edilir; yetki gerektirdiği için `swift test` ile sınanmaz.
- [ ] **Step 5: Commit** — `git commit -m "feat(core): mikrofon ve Core Audio process tap yakalama"`

---

### Task 7: Canlı oturum ve transkript reducer

**Files:**
- Create: `Sources/AINotepadCore/Session/LiveSession.swift`, `Sources/AINotepadCore/Session/TranscriptReducer.swift`
- Test: `Tests/AINotepadCoreTests/TranscriptReducerTests.swift`, `Tests/AINotepadCoreTests/LiveSessionTests.swift`

**Interfaces:**
- Consumes: Task 2–5'in tamamı.
- Produces:
  ```swift
  public enum LiveSessionEvent: Sendable, Equatable {
      case segment(LiveSegment)
      case languageLocked(MeetingLanguage)
      case captureEnded(speaker: Speaker)
      case recordingFailed(speaker: Speaker, message: String)
  }
  public struct LiveSessionConfig: Sendable {
      public let languageMode: LanguageMode; public let segmenter: SegmenterConfig
      public let recordingDirectory: URL; public let partialIntervalSec: Double  // 1.5
      public let minPartialSpeechSec: Double                                      // 1.0
      public let languageLockAfterSec: Double                                     // 30
  }
  public func runLiveSession(config: LiveSessionConfig, engine: any TranscriptionEngine,
                             meAudio: AsyncStream<[Float]>, othersAudio: AsyncStream<[Float]>)
      -> AsyncStream<LiveSessionEvent>
  public func applyEvent(transcript: [LiveSegment], event: LiveSessionEvent) -> [LiveSegment]
  ```

- [ ] **Step 1: Reducer testleri**
  ```swift
  @Test func partialThenFinalReplacesInPlace()  // aynı id: partial "Hyv" → final "Hyvää" → 1 öğe, isFinal true
  @Test func keepsSortedByStart()               // others(5.0) sonra me(2.0) → [me, others]
  @Test func emptyFinalRemovesSegment()         // partial sonra boş final → liste boş
  @Test func failureMarksSegment()              // failureMessage dolu final → öğe kalır, mesaj taşınır
  @Test func nonSegmentEventsDoNotChange()      // .languageLocked → aynı liste
  ```
- [ ] **Step 2: Reducer'ı uygula, testleri geçir** — `--filter TranscriptReducerTests` önce FAIL, sonra PASS.

- [ ] **Step 3: Oturum testi (gerçek model, gerçek ses)** — `AINOTEPAD_MODEL_TESTS=1` ile etkin. `meAudio` = 10 sn sessizlik, `othersAudio` = `fi-meeting.wav`, ikisi de 1600 örneklik parçalar halinde verilip bitirilir. `languageMode: .automatic`, `languageLockAfterSec: 5`, kayıt dizini geçici klasör.
  ```swift
  @Test func finnishMeetingEndToEnd()
  // olaylar bitene kadar topla, applyEvent ile katla:
  // - .languageLocked(.finnish) olayı var
  // - final "others" metinleri birleşimi lowercased içerir "raportti"
  // - hiçbir "me" bölümü yok (sessizlik)
  // - .captureEnded(.me) ve .captureEnded(.others) var
  // - recordingDirectory/others.caf uzunluğu == fixture örnek sayısı, me.caf == 160000
  ```
- [ ] **Step 4: Çalıştır** → FAIL.

- [ ] **Step 5: `runLiveSession`'ı uygula** — içte bir `actor` durumu tutar; davranış:
  - Konuşmacı başına bir görev: her parça önce `CafRecorder.append` (hata → bir kez `.recordingFailed`, transkripsiyon sürer), sonra `segmentAudio`. Kapanan bölümler **final iş** olarak kuyruğa. Akış bitince `flushSegmenter`, kaydediciyi kapat, `.captureEnded`.
  - **Tek seri işçi** (`AsyncStream<TranscriptionJob>` tüketen tek görev); motor çağrıları yalnızca buradan yapılır.
  - Kısmi zamanlayıcı: her `partialIntervalSec`'te, işçi boştaysa ve bir açık bölümde ≥ `minPartialSpeechSec` ses varsa, o bölümün anlık kopyası için **kısmi iş** kuyruğa; işçi meşgulse atlanır. Önce `others`, sonra `me`.
  - Dil: `.fixed` → o dil. `.automatic` + kilitli → kilitli dil. Kilitsizken final işte `detectLanguage` → `addVote` → o bölüm `pickLanguage` ile çevrilir; sonra `lockedLanguage(votes, elapsedSec: job.endSec, lockAfterSec:)` dil verirse kilitlenir ve `.languageLocked` yayınlanır. Kilitsizken kısmi iş `leadingLanguage` kullanır, nil ise atlanır.
  - Motor hatası → `.segment(... text: "", isFinal: true, failureMessage: <hata açıklaması>)`.
  - İki giriş akışı bitip kuyruk boşalınca olay akışı `finish()` olur.
- [ ] **Step 6: Çalıştır** — `AINOTEPAD_MODEL_TESTS=1 swift test --package-path Packages/AINotepadCore --filter LiveSessionTests` → PASS. Ardından model testleri olmadan tüm paket: `swift test --package-path Packages/AINotepadCore` → PASS (model suite'leri atlanır).
- [ ] **Step 7: Commit** — `git commit -m "feat(core): canlı oturum ve transkript reducer"`

---

### Task 8: Uygulama arayüzü (menü + basit panel)

**Files:**
- Create: `App/AppModel.swift`, `App/LivePanel.swift`, `App/LiveTranscriptView.swift`
- Modify: `App/AINotepadApp.swift`

**Interfaces:**
- Consumes: `WhisperKitEngine.load`, `liveWhisperModel`, `MicrophoneCapture`, `SystemAudioCapture`, `runLiveSession`, `applyEvent`, `AppPaths`, `SegmenterConfig.live`.
- Produces (yalnızca uygulama içi):
  ```swift
  enum ModelStatus: Equatable { case loading, ready, failed(String) }
  @MainActor @Observable final class AppModel {
      var modelStatus: ModelStatus; var isRecording: Bool; var languageMode: LanguageMode
      var lockedLanguage: MeetingLanguage?; var transcript: [LiveSegment]; var errorMessages: [String]
      func loadModel() async; func startRecording() async; func stopRecording()
  }
  func makeLivePanel(rootView: some View) -> NSPanel
  ```

- [ ] **Step 1: `AppModel`** — açılışta `loadModel()`. `startRecording`: yeni oturum dizini, iki yakalamayı başlat (biri başarısız olursa hata `errorMessages`'a eklenir ve o akış için boş/bitmiş bir `AsyncStream` verilir; ikisi de başarısızsa kayıt başlamaz), `runLiveSession` olaylarını `applyEvent` ile `transcript`'e katla; `.languageLocked` → `lockedLanguage`; `.recordingFailed` → `errorMessages`. Yeni kayıtta `transcript` ve `lockedLanguage` sıfırlanır. `stopRecording`: iki yakalamanın `stop()`'u; oturum akışı kendiliğinden biter.
- [ ] **Step 2: `makeLivePanel`** — `NSPanel`, stil `[.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow]`, `level = .floating`, `isFloatingPanel = true`, `hidesOnDeactivate = false`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `sharingType = .none`, başlangıç boyutu 380×520, ekranın sağ üstü. İçerik `NSHostingView`.
- [ ] **Step 3: `LiveTranscriptView`** — üstte durum satırı (model durumu: "Model hazırlanıyor…" / "Hazır" / hata; kayıt süresi; dil: kilitliyse "🇫🇮 Fince"/"🇬🇧 İngilizce", değilse "Dil algılanıyor…"). Liste: her bölümde etiket "Sen"/"Diğerleri", metin; `isFinal == false` → %50 opaklık; `failureMessage` → kırmızı küçük metin. Yeni bölümde en alta kaydır. Hata mesajları altta kırmızı.
- [ ] **Step 4: Menü** — "Kaydı başlat" / "Kaydı durdur" (model hazır değilken devre dışı), "Dil" alt menüsü: Otomatik / Fince / İngilizce (kayıt sırasında devre dışı — toplantı ortasında dil değiştirme Aşama 4'te adaya eklenir), "Paneli göster", "Çık". Kayıt başlayınca panel otomatik açılır.
- [ ] **Step 5: Doğrula** — `xcodegen generate && xcodebuild -project AINotepad.xcodeproj -scheme AINotepad -configuration Debug build -quiet` → çıkış 0. Uygulamayı aç; model indirilip "Hazır" olduktan sonra kaydı başlat, mikrofon ve sistem sesi izinlerini ver; YouTube'da Fince bir video oynat → "Diğerleri" altında Fince metin, sen konuşunca "Sen" altında metin görünmeli. Durdur → oturum klasöründe `me.caf` ve `others.caf` olmalı (`afinfo` ile süreleri kontrol et).
- [ ] **Step 6: Commit** — `git commit -m "feat(app): menü çubuğu, canlı transkript paneli"`

---

### Task 9: Gerçek toplantı kontrol listesi

**Files:** Kod değişikliği yok (bulunan hatalar ayrı düzeltme commit'leri olur).

- [ ] **Step 1: Zoom, Fince** — test Zoom toplantısı (ikinci cihaz ya da bir arkadaş) ile Fince konuşma, kulaklıkla. Beklenen: dil 30 sn içinde "Fince" olarak kilitlenir, cümleler ~2–4 sn gecikmeyle görünür, "Sen"/"Diğerleri" doğru.
- [ ] **Step 2: Teams, İngilizce** — aynı kontrol İngilizce ile.
- [ ] **Step 3: 30+ dk dayanıklılık** — 30 dk açık bırak (uzun bir ders videosu). Beklenen: gecikme büyümüyor (kısmi işler atlanıyor, finaller birikmiyor), bellek sabit (Activity Monitor), `.caf` dosyaları büyüyor.
- [ ] **Step 4: Kulaklıksız (Review Focus 1)** — hoparlörle dinle. Gözlemi kaydet: diğerlerinin cümleleri "Sen" altında da çıkıyor mu? Sonucu kullanıcıya raporla; çözüm (ör. `AVAudioInputNode` voice processing) ayrı karar.
- [ ] **Step 5: AirPods değişimi (Review Focus 4)** — kayıt sırasında AirPods bağla/çıkar. Beklenen: "Diğerleri" transkripti devam eder ya da panelde açık hata görünür; sessiz durma yok.
- [ ] **Step 6: İzin reddi (Review Focus 5)** — `tccutil reset Microphone com.senoldogan.AINotepad`, reddet → panelde Türkçe mikrofon hatası, "Diğerleri" çalışmaya devam eder. Aynısı sistem sesi izni için (`tccutil reset AudioCapture com.senoldogan.AINotepad`).
- [ ] **Step 7: Ekran paylaşımı** — Zoom'da tüm ekranı paylaş; panel karşı tarafta görünüyor mu? Sonucu kaydet (spec §4.1: garanti değil, ölçülür).
- [ ] **Step 8: Rapor** — sonuçları kullanıcıya özetle: Fince doğruluk izlenimi, gecikme, Step 4/5/7 bulguları. Fince kalite yetersizse spec §9'a göre bulut motorunun önceliğini kullanıcıyla konuş.
