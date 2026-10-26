# Aşama 5 — Toplantı Sonrası: Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Toplantılar kaydedilir; kayıt bitince en doğru transkript + kesin konuşmacılar + Türkçe not üretilir; geçmiş penceresinde aranır, konuşmacılar adlandırılır, Markdown dışa aktarılır.
**Architecture:** `AINotepadCore/Meeting`: değer tipleri + JSON deposu (bağlayıcı) + saf dönüşümler (son bölümler, not isteği/ayrıştırma, saklama/kurtarma kararları, Markdown) + `processMeeting` orkestrasyonu. Uygulama: `MeetingsWindow` (SwiftUI pencere) + `AppModel` bağlantıları.
**Spec:** `docs/superpowers/specs/2026-10-25-ai-notepad-design.md` §4.1 PostProcessing/Storage, §5

## Global Constraints
- Klasör: `Sessions/<yyyyMMdd-HHmmss>/meeting.json` (atomik yazım, `JSONEncoder` sıralı anahtar, ISO-8601 tarih), ses `me.m4a`/`others.m4a` (AAC 16 kHz mono 32 kbps).
- Son geçiş bölümleme: konuşmacı değişimi ya da > 1,5 sn boşluk. Saklama: 30 gün. Not: Claude Opus, yapılandırılmış çıktı, `timeoutSec` 300.
- Tüm metin Türkçe; varsayılan parametre yok; saf fonksiyonlar.

## Review Focus
1. Uygulama kayıt/işleme sırasında kapanırsa toplantı kaybolmaz → Task 1 `recoveryMarksStaleRecordingsInterrupted`.
2. Bozuk `meeting.json` diğer toplantıları göstermeyi engellemez → Task 1 `corruptFileIsReportedNotFatal`.
3. Saklama süresi metni ve notu silmez, yalnızca sesi → Task 1 `retentionDeletesOnlyOldAudio`.
4. Uzun toplantı (1 sa+) son geçiş isteği zaman aşımına uğramaz → Task 3 zaman aşımı 300 sn + m4a yükleme.
5. Konuşmacı adı değişince not/dışa aktarma yeni adı kullanır → Task 4 `markdownUsesSpeakerNames`.

### Task 1: Kayıt modeli, JSON deposu, saklama ve kurtarma
`Meeting/MeetingRecord.swift` (Codable tipler §5), `Meeting/MeetingStore.swift`: `saveMeeting(record:directory:) throws`, `loadMeetings(sessionsDirectory:) -> MeetingLoadResult {meetings, failures[(folder, reason)]}`, saf `staleStatusesToInterrupt(records:) -> [MeetingRecord]`, `audioToDelete(records:now:retentionDays:) -> [String]` (klasör adları).
Testler: `saveThenLoadRoundTrip`, `corruptFileIsReportedNotFatal`, `recoveryMarksStaleRecordingsInterrupted`, `retentionDeletesOnlyOldAudio`.

### Task 2: Ses sonlandırma (caf → m4a)
`Audio/AudioFinalizer.swift`: `convertToM4A(source:destination:) throws` (AVAudioFile AAC). Test: fixture → caf → m4a, süre ±0,1 sn, kaynak silinmez (çağıran siler).

### Task 3: Son geçiş transkript
`Cloud/ElevenLabsDiarizer.swift`'e `diarizeFile(apiKey:fileURL:mimeType:languageMode:timeoutSec:) async throws -> DiarizationResult` (mevcut multipart'ı paylaşır). `Meeting/FinalTranscript.swift`: saf `finalSegments(words:gapSec:) -> [StoredSegment]` (konuşmacı → kişi numarası ilk görünme sırası).
Testler: `splitsOnSpeakerChangeAndGap`, `personsNumberedByAppearance`. Bulut: `fullFileDiarization` (fi-dialog m4a → ≥2 kişi, "raport" geçer).

### Task 4: Toplantı notu ve Markdown
`Meeting/MeetingNote.swift`: `meetingNoteRequest(segments:speakerNames:userName:) -> ClaudeRequest?`, `parseMeetingNote(text:) throws -> MeetingNote`, `meetingMarkdown(record:) -> String`.
Testler: `noteRequestHasSchemaAndUserName`, `parseMeetingNoteJSON`, `markdownUsesSpeakerNames`. Bulut: `noteFromDialog`.

### Task 5: İşleme orkestrasyonu
`Meeting/ProcessMeeting.swift`: `processMeeting(record:directory:keys:languageMode:userName:) async -> MeetingRecord` (m4a → son geçiş → not; her adım hatası `failed` + mesaj, ses korunur). AppModel: kayıt başlarken `recording` kaydı yazılır; bitince `processing` → `processMeeting` → kaydet. Bulut uçtan uca test: fi-dialog caf'larıyla `done`, not var.

### Task 6: Toplantılar penceresi
`App/MeetingsWindow.swift`: liste (tarih, başlık, durum; arama başlık+metin), ayrıntı (not bölümleri, son transkript; kişi adlandırma alanları; "Markdown kopyala", "Markdown kaydet", "Sesi sil", "Tekrar işle"). Menü: "Toplantılar…". Ayarlar: "Adın". Açılışta kurtarma + saklama.

### Task 7: Kabul listesi + inceleme.
