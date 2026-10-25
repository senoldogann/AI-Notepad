# Aşama 2 — Hibrit STT: Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Canlı metni Deepgram akışıyla ~1 sn'de göstermek ve "Diğerleri"ni ElevenLabs ile dakikada bir "Konuşmacı 1/2/3…" olarak ayırmak; motor ve anahtarlar Ayarlar penceresinden yönetilir.

**Architecture:** Yeni `runCloudLiveSession` mevcut `LiveSessionEvent` akışını üretir; UI ve reducer iki motor için aynıdır. Deepgram bağlantısı ve ElevenLabs istemcisi dış sistem bağlayıcılarıdır; mesaj ayrıştırma, WAV/PCM kodlama ve pencereler arası konuşmacı eşleme saf fonksiyonlardır. WhisperKit yolu (`runLiveSession`) olduğu gibi kalır ve yalnızca seçildiğinde yüklenir.

**Tech Stack:** Swift 6.2, `URLSessionWebSocketTask`, `URLSession` multipart, Security (Keychain), Swift Testing. Ek bağımlılık yok.

**Spec:** `docs/superpowers/specs/2026-10-25-ai-notepad-design.md` (§2 Konuşma tanıma, §4.1 Transcription / LiveDiarization / Settings, §6, §8 aşama 2, §9)

## Global Constraints

- macOS 26+, Swift 6 strict concurrency; yorumlar ve UI metni Türkçe; varsayılan parametre değeri yok; saf fonksiyonlar; `class`/`actor` yalnızca bağlayıcılarda.
- Keychain: servis `AINotepad`, hesaplar `deepgram`, `elevenlabs`. Anahtar asla loglanmaz, hata mesajına girmez.
- Deepgram: `wss://api.deepgram.com/v1/listen?model=nova-3&encoding=linear16&sample_rate=16000&channels=1&interim_results=true&smart_format=true&language=<fi|en|multi>`, başlık `Authorization: Token <anahtar>`; kapanışta metin mesajı `{"type":"CloseStream"}`.
- Dil eşlemesi: Deepgram her zaman somut dil alır (`fi` | `en`). Otomatik: `fi` ile başlar, ilk ayırma penceresinin (15. sn) ElevenLabs `language_code` sonucu olasılık ≥ 0,8 ile `eng` ise iki akış `en`'e geçer (bkz. ledger Task 3 kararı).
- ElevenLabs: `POST https://api.elevenlabs.io/v1/speech-to-text`, başlık `xi-api-key`, multipart alanlar `model_id=scribe_v2`, `diarize=true`, `file` (WAV), `language_code` = `fin` | `eng` (Otomatik'te gönderilmez).
- Konuşmacı ayırma: ilk pencere 15. sn, sonra her 60 sn, "Diğerleri"nin son 120 sn'si; 5 sn'den kısa pencere gönderilmez.
- Dış HTTP çağrıları: 3 deneme, üstel bekleme, her başarısızlıkta uyarı logu, sonra son hata; hata durum kodu + yanıt gövdesi içerir.
- Deepgram yeniden bağlanma: 4 deneme, 0,25 sn'den başlayan üstel bekleme; kopukken gelen ses tamponlanıp bağlanınca gönderilir.
- Gizli yedek yok: bulut başarısızsa WhisperKit'e geçilmez; hata panelde görünür; `.caf` kaydı sürer.
- Bulut testleri yalnızca `AINOTEPAD_CLOUD_TESTS=1` ile; anahtarlar testte `/usr/bin/security find-generic-password -s AINotepad -a <hesap> -w` ile okunur.

## Review Focus

1. **İnternet toplantı ortasında kopar ve geri gelir:** metin akışı birkaç saniye sonra devam etmeli, zaman damgaları geriye sarmamalı, aradaki ses kaybolmamalı → Task 3 `timelineOffsetsAcrossReconnects` + Task 9 adım 3.
2. **Geçersiz/süresi dolmuş anahtar ya da kota bitti:** sessiz boş panel değil, Türkçe açık hata; kayıt sürer → Task 3 `invalidKeyFailsWithStatus`, Task 4 `invalidKeyThrowsWithStatus`, Task 8 adım 5.
3. **Aynı kişi pencereden pencereye farklı numara alır:** örtüşmede eşleme kimliği korumalı → Task 5 `overlapKeepsIdentityWhenLabelsSwap`, `twoLabelsCannotClaimSamePerson`.
4. **Pencerede hiç konuşma yok (sessizlik, müzik):** hata değil, etiket değişmez → Task 5 `emptyWindowKeepsMapping`, Task 7 kısa pencere atlama.
5. **Otomatik modda İngilizce toplantı:** dil algılanınca iki akış İngilizceye geçmeli, metin akmaya devam etmeli → Task 3 `switchesLanguageMidStream`, Task 7 `englishMeetingSwitchesLanguage`.

---

## Dosya yapısı

```
scripts/make-test-fixtures.sh                     + fi-dialog.wav (3 Fince ses, sırayla)
Packages/AINotepadCore/Sources/AINotepadCore/
  Support/Keychain.swift                          readSecret / saveSecret / deleteSecret
  Support/Retry.swift                             retryWithBackoff → async + isolation (değişir)
  Cloud/CloudSTTError.swift
  Cloud/AudioEncoding.swift                       linear16Data, wavData
  Cloud/DeepgramMessages.swift                    ayrıştırma + URL
  Cloud/DeepgramStream.swift                      streamDeepgram (WebSocket bağlayıcı)
  Cloud/ElevenLabsDiarizer.swift                  ayrıştırma + diarizeWithElevenLabs
  Diarization/SpeakerMapping.swift                applyWindow, assignPersons
  Session/CloudLiveSession.swift                  runCloudLiveSession
  Model/TranscriptTypes.swift                     LiveSegment.person (değişir)
  Session/LiveSessionEvent.swift                  yeni olaylar (değişir)
  Session/TranscriptReducer.swift, TranscriptFormatting.swift   (değişir)
  Audio/MicrophoneCapture.swift, SystemAudioCapture.swift       (retry çağrısı değişir)
Packages/AINotepadCore/Tests/AINotepadCoreTests/
  KeychainTests, AudioEncodingTests, DeepgramMessageTests, DeepgramStreamTests,
  ElevenLabsTests, SpeakerMappingTests, CloudLiveSessionTests, CloudTestSupport.swift
App/
  SettingsView.swift (yeni), AppModel.swift, AINotepadApp.swift, LiveTranscriptView.swift (değişir)
```

---

### Task 1: Çok konuşmacılı test sesi, Keychain ve bulut test altyapısı

**Files:**
- Modify: `scripts/make-test-fixtures.sh`; Create: `Tests/.../Fixtures/fi-dialog.wav`
- Create: `Sources/AINotepadCore/Support/Keychain.swift`, `Tests/.../KeychainTests.swift`, `Tests/.../CloudTestSupport.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum SecretAccount: String, Sendable { case deepgram, elevenlabs }
  public let keychainService: String = "AINotepad"
  public enum KeychainError: Error, Equatable {
      case notFound(service: String, account: String)
      case unexpectedStatus(operation: String, status: Int32)
  }
  public func readSecret(service: String, account: SecretAccount) throws -> String
  public func saveSecret(service: String, account: SecretAccount, value: String) throws  // varsa günceller
  public func deleteSecret(service: String, account: SecretAccount) throws               // yoksa hata değil
  // Test hedefi:
  let cloudTestsEnabled: Bool                            // AINOTEPAD_CLOUD_TESTS == "1"
  func cloudKey(account: SecretAccount) throws -> String // /usr/bin/security ile okur
  @Suite(.enabled(if: cloudTestsEnabled), .serialized) struct CloudTests {}
  ```

- [ ] **Step 1: Fixture** — betiğe `fi-dialog.wav` ekle: `say -v '?'` çıktısından `fi_FI` olan ilk üç farklı sesi seç; sırayla, aralarına `[[slnc 700]]`:
  1. "Hyvää huomenta, aloitetaan palaveri." 2. "Kiitos. Minulla on raportti valmiina." 3. "Hienoa, esitys on perjantaina." 4. "Selvä, lähetän raportin huomenna."
  Her cümle kendi sesiyle ayrı `.aiff` → `afconvert -f WAVE -d LEI16@16000 -c 1` ile `.wav`; parçalar yeni
  `scripts/concat-wav.swift` (AVAudioFile ile sırayla okuyup tek WAV'a yazar; argümanlar: çıkış yolu, girişler)
  ile birleştirilir. Çalıştır, `afinfo` ile 16 kHz mono doğrula, `.wav`'ı commit'e ekle.
- [ ] **Step 2: Failing testler** (`KeychainTests`, gerçek Keychain, servis `"AINotepad.tests"`):
  ```swift
  @Test func saveThenReadReturnsValue()      // save "abc" → read == "abc"; sonunda delete
  @Test func saveOverwritesExisting()        // save "a", save "b" → read == "b"
  @Test func readMissingThrowsNotFound()     // delete, read → throws .notFound(service: "AINotepad.tests", account: "deepgram")
  ```
- [ ] **Step 3: Çalıştır** — `swift test --package-path Packages/AINotepadCore --filter KeychainTests` → FAIL (tanımsız).
- [ ] **Step 4: Uygula** — `SecItemCopyMatching` / `SecItemUpdate` / `SecItemAdd` / `SecItemDelete`, `kSecClassGenericPassword`. `errSecItemNotFound` → `.notFound`; diğerleri `.unexpectedStatus`. `CloudTestSupport.swift`: yukarıdaki üç test yardımcısı (`Process` ile `security`, çıkış kodu ≠ 0 → hata).
- [ ] **Step 5: Çalıştır** → PASS. **Commit:** `feat(core): Keychain erişimi, çok konuşmacılı test sesi, bulut test altyapısı`

---

### Task 2: Ses kodlama ve Deepgram mesaj ayrıştırma

**Files:**
- Create: `Sources/AINotepadCore/Cloud/CloudSTTError.swift`, `Cloud/AudioEncoding.swift`, `Cloud/DeepgramMessages.swift`
- Test: `Tests/.../AudioEncodingTests.swift`, `Tests/.../DeepgramMessageTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum CloudSTTError: Error, Equatable {
      case http(service: String, status: Int, body: String)
      case malformedMessage(service: String, body: String)
      case connectionFailed(service: String, reason: String)
  }
  public func linear16Data(samples: [Float]) -> Data              // [-1,1] kırpılır, Int16 little-endian
  public func wavData(samples: [Float], sampleRate: Int) -> Data   // 44 baytlık RIFF başlık + linear16
  public struct DeepgramResult: Sendable, Equatable { public let startSec: Double; public let endSec: Double
      public let transcript: String; public let isFinal: Bool }
  public enum DeepgramMessage: Sendable, Equatable { case results(DeepgramResult), metadata(requestID: String), other(type: String) }
  public func parseDeepgramMessage(data: Data) throws -> DeepgramMessage
  public func deepgramListenURL(languageMode: LanguageMode) -> URL
  ```

- [ ] **Step 1: Failing testler**
  ```swift
  @Test func linear16ClampsAndEncodesLittleEndian()  // [0, 1, -1, 2] → bayt [0,0, 0xFF,0x7F, 0x01,0x80, 0xFF,0x7F]
  @Test func wavHeaderDescribes16kMono()             // wavData(16000 örnek) → count 44+32000; "RIFF","WAVE",
                                                      // fmt kanal 1, örnekleme 16000, bit 16; data boyutu 32000
  @Test func parsesInterimResult()     // {"type":"Results","start":4.2,"duration":4.0,"is_final":false,
                                        //  "channel":{"alternatives":[{"transcript":"Hei"}]}} → .results(4.2, 8.2, "Hei", false)
  @Test func parsesFinalResult()       // aynı, is_final true
  @Test func parsesMetadata()          // {"type":"Metadata","request_id":"r1"} → .metadata(requestID: "r1")
  @Test func unknownTypeIsOther()      // {"type":"SpeechStarted"} → .other(type: "SpeechStarted")
  @Test func malformedThrows()         // "{nope" → throws CloudSTTError.malformedMessage(service: "deepgram", body: "{nope")
  @Test func urlUsesMultiForAutomatic()    // .automatic → query içerir "language=multi", "model=nova-3",
                                           // "encoding=linear16", "sample_rate=16000", "interim_results=true"
  @Test func urlUsesFiForFinnish()         // .fixed(.finnish) → "language=fi"
  ```
- [ ] **Step 2: Çalıştır** — `--filter "AudioEncodingTests|DeepgramMessageTests"` → FAIL.
- [ ] **Step 3: Uygula** — `Decodable` ara tipler; `endSec = start + duration`; `transcript` alternatives[0]. Gerçek mesaj şekli `/tmp/ainotepad-spike/deepgram-multi.json`'daki gibidir (alanlar: `type`, `start`, `duration`, `is_final`, `speech_final`, `channel.alternatives[].transcript/words`).
- [ ] **Step 4: Çalıştır** → PASS. **Commit:** `feat(core): PCM/WAV kodlama ve Deepgram mesaj ayrıştırma`

---

### Task 3: Deepgram akış bağlayıcısı (yeniden bağlanmalı)

**Files:**
- Create: `Sources/AINotepadCore/Cloud/DeepgramStream.swift`, `Tests/.../DeepgramStreamTests.swift`
- Modify: `Sources/AINotepadCore/Support/Retry.swift`, `Audio/MicrophoneCapture.swift`, `Audio/SystemAudioCapture.swift`, `Tests/.../RetryTests.swift`

**Interfaces:**
- Consumes: Task 2 tümü.
- Produces:
  ```swift
  // Retry tek fonksiyon olur; çağıran kendi izolasyonunu açıkça verir (#isolation).
  public func retryWithBackoff(attempts: Int, delaySec: Double, isolation: isolated (any Actor)?,
                               operation: () async throws -> Void, onFailure: (Int, any Error) -> Void) async throws
  public enum StreamingEvent: Sendable, Equatable {
      case partial(text: String, startSec: Double, endSec: Double)
      case final(text: String, startSec: Double, endSec: Double)
      case failed(message: String)
  }
  public func absoluteTime(deepgramSec: Double, connectionStartSample: Int, sampleRate: Int) -> Double
  public func streamDeepgram(apiKey: String, languageMode: LanguageMode, audio: AsyncStream<[Float]>) -> AsyncStream<StreamingEvent>
  ```

- [ ] **Step 1: Retry imzasını değiştir (test önce)** — `RetryTests`'i yeni imzaya çevir (`isolation: MainActor.shared`, async operation); ek test `asyncOperationIsAwaited` (operation içinde `Task.sleep(0.01)` sonra sayaç artırır → 2. denemede başarı). Çalıştır → FAIL; `Retry.swift`'i değiştir; yakalayıcılardaki iki çağrıya `isolation: #isolation` ekle. Çalıştır → PASS.
- [ ] **Step 2: Failing testler**
  ```swift
  @Test func timelineOffsetsAcrossReconnects()   // absoluteTime(deepgramSec: 2.5, connectionStartSample: 160_000, sampleRate: 16000) == 12.5
  // CloudTests altında (gerçek servis):
  @Test func streamsFinnishDialog()   // fi-dialog.wav 3200'lük parçalar, .automatic → en az 2 .final;
                                      // kesin metinlerin birleşimi lowercased içerir "raportti" ya da "raportin";
                                      // final startSec'ler artan; kesin metinde U+0600–U+06FF ve U+0400–U+04FF yok
  @Test func invalidKeyFailsWithStatus() // apiKey "gecersiz" → ilk olay .failed, mesaj "401" içerir
  ```
- [ ] **Step 3: Çalıştır** — `AINOTEPAD_CLOUD_TESTS=1 swift test ... --filter DeepgramStreamTests` → FAIL.
- [ ] **Step 4: Uygula `streamDeepgram`** — içte bir `actor` bağlantıyı yönetir:
  - `URLSessionWebSocketTask` (`URLRequest`'e `Authorization: Token`). Ses parçaları `linear16Data` ile ikili mesaj; gönderilen toplam örnek sayısı tutulur.
  - Alıcı döngüsü `parseDeepgramMessage`; `.results` → `isFinal ? .final : .partial`, zamanlar `absoluteTime(..., connectionStartSample:)`; boş kesin metin yayınlanmaz.
  - Bağlantı beklenmedik koparsa: gelen ses tampona; `retryWithBackoff(attempts: 4, delaySec: 0.25, isolation: self, ...)` ile yeniden bağlan, `connectionStartSample = toplam gönderilen`, tamponu gönder. Denemeler tükenirse `.failed(message: <Türkçe özet + durum/kod>)` ve akış biter.
  - El sıkışma 4xx (geçersiz anahtar) yeniden denenmez: `.failed` mesajı HTTP durumunu içerir (`URLSessionWebSocketTask` yanıtındaki `HTTPURLResponse.statusCode`).
  - Ses akışı bitince `{"type":"CloseStream"}` gönder, sunucu kapatana ya da 5 sn dolana kadar sonuçları al, akışı bitir.
  - Anahtar hiçbir log/hata metnine girmez.
- [ ] **Step 5: Çalıştır** → PASS (hem hızlı hem bulut). **Commit:** `feat(core): Deepgram akış bağlayıcısı, yeniden bağlanma`

---

### Task 4: ElevenLabs konuşmacı ayırma istemcisi

**Files:**
- Create: `Sources/AINotepadCore/Cloud/ElevenLabsDiarizer.swift`, `Tests/.../ElevenLabsTests.swift`

**Interfaces:**
- Consumes: `wavData`, `CloudSTTError`, `retryWithBackoff`.
- Produces:
  ```swift
  public struct DiarizedWord: Sendable, Equatable { public let text: String; public let startSec: Double
      public let endSec: Double; public let speaker: String }
  public func parseElevenLabsWords(data: Data) throws -> [DiarizedWord]   // yalnızca type == "word"
  public func elevenLabsLanguageCode(languageMode: LanguageMode) -> String?  // fin | eng | nil
  public func diarizeWithElevenLabs(apiKey: String, samples: [Float], languageMode: LanguageMode) async throws -> [DiarizedWord]
  ```

- [ ] **Step 1: Failing testler**
  ```swift
  @Test func parsesWordsAndSkipsSpacing()  // words: [{text:"Hei",start:0.1,end:0.4,type:"word",speaker_id:"speaker_0"},
                                           //  {text:" ",type:"spacing",...}, {text:"Moi",...,speaker_id:"speaker_1"}] → 2 kelime
  @Test func wordWithoutSpeakerThrows()    // type "word" ama speaker_id yok → throws .malformedMessage(service: "elevenlabs", ...)
  @Test func languageCodes()               // .automatic → nil, .fixed(.finnish) → "fin", .fixed(.english) → "eng"
  // CloudTests altında:
  @Test func diarizesDialogIntoSeveralSpeakers() // fi-dialog.wav, .automatic → kelimeler boş değil, farklı speaker ≥ 2
  @Test func invalidKeyThrowsWithStatus()        // "gecersiz" → throws .http(service: "elevenlabs", status: 401, …)
  ```
- [ ] **Step 2: Çalıştır** → FAIL.
- [ ] **Step 3: Uygula** — multipart gövde (`boundary` UUID); 3 deneme (`retryWithBackoff`, `isolation: nil`), 4xx yeniden denenmez; 2xx dışı → `.http(status, body)`. Gerçek yanıt şekli `/tmp/ainotepad-spike/elevenlabs-diarize.json`.
- [ ] **Step 4: Çalıştır** → PASS. **Commit:** `feat(core): ElevenLabs konuşmacı ayırma istemcisi`

---

### Task 5: Pencereler arası konuşmacı eşleme (saf)

**Files:**
- Create: `Sources/AINotepadCore/Diarization/SpeakerMapping.swift`, `Tests/.../SpeakerMappingTests.swift`

**Interfaces:**
- Consumes: `DiarizedWord`, `LiveSegment`, `SegmentID`.
- Produces:
  ```swift
  public struct AttributedWord: Sendable, Equatable { public let startSec: Double; public let endSec: Double; public let person: Int }
  public struct SpeakerMapping: Sendable, Equatable { public let words: [AttributedWord]; public let nextPerson: Int
      public static let initial: SpeakerMapping   // words [], nextPerson 1 }
  public func applyWindow(mapping: SpeakerMapping, windowWords: [DiarizedWord], windowStartSec: Double) -> SpeakerMapping
  public func assignPersons(segments: [LiveSegment], words: [AttributedWord]) -> [SegmentID: Int]
  ```
- Algoritma (`applyWindow`): pencere kelimeleri `windowStartSec` eklenerek mutlak zamana çevrilir. Her yeni etiket L ve önceki kişi P için örtüşme = Σ |L kelimesi ∩ P kelimesi| (zaman kesişim süresi). (L, P) çiftleri örtüşmeye göre büyükten küçüğe açgözlü eşlenir; her L ve P en fazla bir kez; örtüşme > 0 şart. Eşlenmeyen etiketler, pencerede ilk görünme sırasına göre `nextPerson`'dan numara alır. Dönen `words` = bu pencerenin atanmış kelimeleri; kelime yoksa eşleme aynen döner.
- `assignPersons`: yalnızca `.others` bölümleri; her bölüm için bölüm aralığıyla kesişen kelime süreleri kişi başına toplanır, en büyük kişi atanır; kesişim yoksa atanmaz.

- [ ] **Step 1: Failing testler**
  ```swift
  @Test func firstWindowNumbersInOrderOfAppearance() // [b@0-1, a@1-2] → b→1, a→2, nextPerson 3
  @Test func overlapKeepsIdentityWhenLabelsSwap()   // pencere1 (start 0): A 0-60, B 60-120; pencere2 (start 60):
                                                    // etiketler ters (speaker_0 = eski B 0-60 göreli, speaker_1 = 60-120) →
                                                    // speaker_0 → kişi 2, speaker_1 → yeni kişi 3
  @Test func twoLabelsCannotClaimSamePerson()       // iki yeni etiket aynı eski kişiyle örtüşür → büyük örtüşen alır, diğeri yeni numara
  @Test func newSpeakerGetsNextNumber()
  @Test func emptyWindowKeepsMapping()              // windowWords [] → mapping == önceki
  @Test func assignPersonsByMajorityDuration()      // bölüm 0-10; kişi1 0-3, kişi2 3-10 → 2
  @Test func segmentWithoutWordsUnassigned()
  @Test func meSegmentsAreIgnored()
  ```
- [ ] **Step 2–4:** Çalıştır → FAIL; uygula; çalıştır → PASS. **Commit:** `feat(core): pencereler arası konuşmacı eşleme`

---

### Task 6: Kişi etiketleri — tipler, olaylar, reducer, biçimlendirme

**Files:**
- Modify: `Model/TranscriptTypes.swift`, `Session/LiveSessionEvent.swift`, `Session/TranscriptReducer.swift`, `Session/TranscriptFormatting.swift`, `Session/LiveSession.swift` (yeni alanı `nil` ile geçir), mevcut testlerdeki `LiveSegment` kurulumları; `App/AppModel.swift` ve `App/LiveTranscriptView.swift`'teki `speakerLabel` çağrıları (`person:` ile; yeni olaylar `switch`'e eklenir) — uygulama bu görevin sonunda da derlenmeli
- Test: `Tests/.../TranscriptReducerTests.swift`, `Tests/.../TranscriptFormattingTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // LiveSegment'e eklenir (init'e de): public let person: Int?
  // LiveSessionEvent'e eklenir:
  case speakersAssigned([SegmentID: Int])
  case streamFailed(speaker: Speaker, message: String)
  case diarizationFailed(message: String)
  // SpeakerBlock'a eklenir: public let person: Int?
  public func speakerLabel(speaker: Speaker, person: Int?) -> String   // person varsa "Konuşmacı N"; yoksa "Sen"/"Diğerleri"
  ```
  Eski `speakerLabel(speaker:)` kaldırılır (tek imza).

- [ ] **Step 1: Failing testler**
  ```swift
  @Test func speakersAssignedSetsPerson()        // others#0 → [id: 2] → person 2
  @Test func laterUpdateKeepsAssignedPerson()    // atanmış partial'ın finali gelir (person nil) → person 2 korunur
  @Test func groupsSplitByPerson()               // others p1, others p1, others p2 → 2 blok
  @Test func plainTextUsesPersonLabel()          // "[00:05] Konuşmacı 2: …"
  ```
- [ ] **Step 2–4:** FAIL → uygula (reducer yeni olayları bilir; `streamFailed`/`diarizationFailed` transkripti değiştirmez) → tüm hızlı testler PASS ve `xcodebuild … build` uyarısız. **Commit:** `feat(core): kişi etiketleri ve yeni oturum olayları`

---

### Task 7: Bulut canlı oturumu

**Files:**
- Create: `Sources/AINotepadCore/Session/CloudLiveSession.swift`, `Tests/.../CloudLiveSessionTests.swift`

**Interfaces:**
- Consumes: `streamDeepgram`, `diarizeWithElevenLabs`, `applyWindow`, `assignPersons`, `CafRecorder`, Task 6 olayları.
- Produces:
  ```swift
  public struct CloudSessionConfig: Sendable {
      public let languageMode: LanguageMode; public let recordingDirectory: URL
      public let deepgramKey: String; public let elevenLabsKey: String
      public let diarizationIntervalSec: Double   // 60
      public let diarizationWindowSec: Double     // 120
      public let minDiarizationAudioSec: Double   // 5
  }
  public func runCloudLiveSession(config: CloudSessionConfig, meAudio: AsyncStream<[Float]>,
                                  othersAudio: AsyncStream<[Float]>) -> AsyncStream<LiveSessionEvent>
  ```
- Davranış:
  - Konuşmacı başına: her parça `CafRecorder`'a (hata → bir kez `.recordingFailed`), sonra Deepgram'a giden akışa; "Diğerleri" ayrıca son `diarizationWindowSec` sesini tutan halka tampona (mutlak başlangıç örneğiyle).
  - `StreamingEvent` → `LiveSegment(id: SegmentID(speaker, index), …, person: nil)`; index her `.final`'dan sonra artar; `.failed` → `.streamFailed`.
  - Ayırıcı görev her `diarizationIntervalSec`'te: tampon < `minDiarizationAudioSec` ise atla; değilse `diarizeWithElevenLabs` → `applyWindow` → o ana kadarki "Diğerleri" kesin bölümleri üzerinde `assignPersons` → boş değilse `.speakersAssigned`. Hata → `.diarizationFailed(message:)`, sonraki pencere denenir.
  - İki ses akışı bitince: Deepgram akışları kapanıp boşalır, son bir ayırma penceresi çalışır, `.captureEnded` ×2, olay akışı biter.
- [ ] **Step 1: Failing test** (CloudTests altında)
  ```swift
  @Test func finnishDialogEndToEnd()
  // me = 12 sn sessizlik, others = fi-dialog.wav; ikisi de 3200'lük parçalarla gerçek zaman hızında
  // (her parçadan sonra 0,2 sn bekle — 2× hız); diarizationIntervalSec 1000 (yalnızca son pencere çalışır)
  // → kesin "Diğerleri" metni "raportti"/"raportin" içerir; .speakersAssigned var ve ≥ 2 farklı kişi;
  //   .captureEnded ×2; others.caf uzunluğu == fixture örnek sayısı; .streamFailed ve .diarizationFailed yok
  ```
- [ ] **Step 2–4:** FAIL → uygula → `AINOTEPAD_CLOUD_TESTS=1 swift test --package-path Packages/AINotepadCore` tümü PASS. **Commit:** `feat(core): Deepgram + ElevenLabs canlı oturumu`

---

### Task 8: Uygulama — Ayarlar, motor seçimi, kişi etiketleri

**Files:**
- Create: `App/SettingsView.swift`; Modify: `App/AppModel.swift`, `App/AINotepadApp.swift`, `App/LiveTranscriptView.swift`

**Interfaces:**
- Consumes: Task 1 Keychain, Task 7 `runCloudLiveSession`, Task 6 etiketler.
- Produces (uygulama içi):
  ```swift
  enum LiveEngine: String, CaseIterable { case deepgram, whisperKit }   // UserDefaults "liveEngine", varsayılan deepgram
  ```
- [ ] **Step 1: `SettingsView`** — SwiftUI `Settings` sahnesi: "Canlı motor" seçici (Deepgram (bulut) / Mac'te (WhisperKit)); Deepgram ve ElevenLabs için `SecureField` + "Kaydet" (`saveSecret(service: keychainService, ...)`); kayıtlı anahtar varsa alan altında "Kayıtlı ✓" (değer gösterilmez). Kaydetme hatası alanın altında kırmızı.
- [ ] **Step 2: `AppModel`** — `liveEngine` değişince: `.whisperKit` → `loadModel()`; `.deepgram` → model yüklenmez, `modelStatus` durum metni "Bulut (Deepgram)". `startRecording`: motor `.deepgram` ise iki anahtarı `readSecret` ile oku; biri yoksa kayıt başlamaz, hata: "Deepgram/ElevenLabs anahtarı yok. Ayarlar'dan ekle." Sonra `runCloudLiveSession(... diarizationIntervalSec: 60, diarizationWindowSec: 120, minDiarizationAudioSec: 5)`. Yeni olaylar: `.streamFailed` → "\(speakerLabel) metin akışı durdu: …"; `.diarizationFailed` → "Konuşmacı ayırma başarısız: …".
- [ ] **Step 3: Menü** — "Ayarlar…" (`SettingsLink`); "Kaydı başlat" `.deepgram`'da model durumuna bakmaz.
- [ ] **Step 4: Panel** — blok etiketi `speakerLabel(speaker:person:)`; kişi rengi: "Sen" vurgu rengi, kişiler `secondary`.
- [ ] **Step 5: Doğrula** — derleme uyarısız. Uygulamayı aç: Ayarlar'da iki anahtar "Kayıtlı ✓" (Keychain izni sorarsa "Her Zaman İzin Ver"); ElevenLabs anahtarını geçici olarak "gecersiz" kaydedip kayıt başlat → panelde kırmızı "Konuşmacı ayırma başarısız … 401" ve metin akmaya devam eder; doğru anahtarı geri kaydet. **Commit:** `feat(app): Ayarlar penceresi, bulut motoru, kişi etiketleri`

---

### Task 9: Kabul testi (elle, kullanıcıyla)

- [ ] **Step 1:** Fince YouTube videosu, motor Deepgram: kesin metin ~1 sn'de; ~1–2 dk içinde "Diğerleri" blokları "Konuşmacı N" olur; aynı kişi numara değiştirmez (gözlem).
- [ ] **Step 2:** İngilizce video, dil "Otomatik": metin İngilizce, kişiler ayrılıyor.
- [ ] **Step 3 (Review Focus 1):** Kayıt sürerken Wi-Fi'yi 10 sn kapat-aç → metin kendiliğinden devam eder, kopukluk süresindeki konuşma birkaç saniye gecikmeyle gelir; kalıcı kopuklukta panelde açık hata.
- [ ] **Step 4:** AirPods bağla/çıkar; mikrofon ve sistem sesi izni reddi (aşama 1'den taşındı).
- [ ] **Step 5:** Motoru WhisperKit'e çevir → model yüklenir ve aşama 1 davranışı aynen çalışır.
- [ ] **Step 6:** Deepgram ve ElevenLabs panellerinde 10 dk kaydın gerçek maliyetini not et; spec §9'daki tahminle karşılaştır.
