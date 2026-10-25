# AI-Notepad — Tasarım Belgesi

Tarih: 2026-10-25 · Durum: Onaylandı

## 1. Amaç

Finlandiya'da yaşayan, ana dili Türkçe olan bir öğrenci; Teams, Zoom ve benzeri
uygulamalardaki Fince veya İngilizce toplantılarda neyi kaçırdığını bilmek istiyor.
AI-Notepad toplantıyı canlı olarak yazıya döker, Türkçeye çevirir, istendiğinde
"ne kaçırdım?" özetini verir ve toplantı bitince Türkçe, yapılandırılmış bir not üretir.

**Başarı ölçütü:** Toplantıdan sonra "neyi kaçırdım?" endişesi kalmaması; kararların ve
kullanıcıya düşen görevlerin Türkçe ve net biçimde görülebilmesi.

## 2. Kısıtlar ve temel kararlar

| Konu | Karar |
|---|---|
| Platform | Sadece macOS 26+, Apple Silicon |
| Dil / UI | Swift 6 + SwiftUI (gerektiğinde AppKit `NSPanel`) |
| Kullanıcı | Tek kullanıcı; hesap, sunucu, paylaşım yok |
| Dağıtım | GitHub'da açık kaynak (MIT); kodda hiçbir API anahtarı yok |
| Veri | Tüm toplantılar yalnızca kullanıcının Mac'inde saklanır |
| Toplantı dili | Bir toplantı tek dillidir (Fince **veya** İngilizce). Varsayılan "Otomatik", elle de seçilebilir |
| Kod stili | Veri `struct`, mantık saf fonksiyon; `actor`/`class` yalnızca dış sistem bağlayıcılarında. Yorumlar Türkçe |

**Doğrulanmış bilgi:** Apple `SpeechTranscriber` bu Mac'te (macOS 26.6) 30 dil destekliyor;
Fince ve Türkçe aralarında **yok**. Bu yüzden yerel STT motoru WhisperKit'tir.

## 3. Kapsam

**Kapsamda (v1):**
- Menü çubuğu ikonu + global kısayolla elle kayıt başlatma/durdurma
- Mikrofon ("Sen") ve sistem sesi ("Diğerleri") ayrı akışlar olarak yakalama
- Canlı transkript + Türkçe çeviri; görünüm: "İki dil" veya "Sadece Türkçe"
- Otomatik dil algılama (ilk 30 sn sonra sabitlenir) ve elle dil seçimi
- "Ne kaçırdım?" butonu (son N dk özeti, varsayılan 3) ve Türkçe soru kutusu
- Toplantı sonrası: ikinci geçiş transkripsiyon, konuşmacı ayrıştırma, yapılandırılmış not
- Not içeriği: Türkçe özet, kararlar, görevler (kullanıcınınkiler vurgulu),
  tam transkript, terimler sözlüğü, Markdown dışa aktarma/kopyalama
- Ses kaydı: varsayılan 30 gün saklanır, sonra otomatik silinir; elle de silinebilir
- STT motorları: yerel (WhisperKit) ve bulut (OpenAI uyumlu); canlı ve toplantı sonrası
  için ayrı ayrı seçilir
- LLM sağlayıcıları: Anthropic API ve OpenAI uyumlu API (OpenAI, Ollama ve OpenAI uyumlu
  uç nokta sunan diğer servisler)
- Arayüz: çentikteki ada + Liquid Glass cam panel + ana pencere (geçmiş) + ayarlar

**Kapsam dışı (v1):**
- Toplantıyı otomatik algılama / otomatik kayıt başlatma
- Kullanıcının toplantı sırasında kendi notlarını yazması
- Adın geçtiğinde/soru sorulduğunda uyarı
- Canlı panelde konuşmacı ayrıştırma (canlıda yalnızca "Sen" / "Diğerleri")
- Aynı toplantıda birden fazla dil
- Windows/Linux, iOS, senkronizasyon

## 4. Mimari

```
AudioCapture ──► Transcription ──► LLM (çeviri) ──► Canlı UI (ada + cam panel)
 (mik + sistem)   (WhisperKit/bulut)                    │
     │                                                   │
     ▼                                                   ▼
 .caf → .m4a ──► PostProcessing ──────────────────► Storage ──► Ana pencere
                 (2. geçiş STT + diarization + not)  (SQLite)   (geçmiş, not, dışa aktarma)
```

Proje yapısı: Xcode uygulama hedefi (`AINotepad`) + yerel Swift paketi (`AINotepadCore`).
Tüm mantık pakette yaşar; uygulama hedefi yalnızca UI ve yaşam döngüsünü içerir.
Böylece mantık `swift test` ile uygulama açılmadan test edilir.

### 4.1 Modüller

**AudioCapture**
- Mikrofon: `AVAudioEngine`.
- Sistem sesi: Core Audio process tap (kendi süreci hariç tüm sistem çıkışı). Ekran kaydı
  izni gerektirmez; `NSAudioCaptureUsageDescription` ile ses yakalama izni ister.
- Çıktı: iki akış, 16 kHz mono Float32 — `speaker = .me` ve `speaker = .others`.
- Eşzamanlı olarak diske iki mono `.caf` yazar (`me.caf`, `others.caf`; 16 kHz Int16). İki cihazın
  saatleri farklı olduğu için akışlar ayrı dosyalarda tutulur. Toplantı bitince ikisi tek bir
  2 kanallı `.m4a`'da birleştirilir (sol: Sen, sağ: Diğerleri) ve `.caf`'ler silinir.
- STT/LLM'den tamamen bağımsızdır: aşağı akıştaki hiçbir hata kaydı durdurmaz.

**Transcription**
- `protocol TranscriptionEngine` — iki uygulama:
  - `WhisperKitEngine`: canlıda `large-v3-turbo`, toplantı sonrasında `large-v3`.
    Model ilk kullanımda indirilir; ilerleme UI'da gösterilir.
  - `CloudTranscriptionEngine`: OpenAI uyumlu `/v1/audio/transcriptions`
    (temel URL + anahtar + model ayarlanabilir; OpenAI, Groq vb.).
- Ses bölümleme (VAD): sessizlikte kesilir, bir bölüm en fazla ~15 sn.
  Devam eden bölüm "geçici" (soluk), biten bölüm "kesin" olarak yayınlanır.
- Dil: "Otomatik" modda ilk 30 sn içindeki algılamalarla dil belirlenir ve sabitlenir.
  Kullanıcı dili değiştirirse yeni dil o andan itibaren uygulanır.

**LLM**
- `protocol LLMClient` — `AnthropicClient`, `OpenAICompatibleClient`.
- Görevler (her biri ayrı, tek amaçlı fonksiyon):
  - `translateSegment`: yalnızca "Diğerleri"nin kesin bölümleri; son birkaç bölüm bağlam olarak eklenir.
  - `summarizeRecent`: son N dk → *konu*, *kararlar*, *senden istenenler*.
  - `answerQuestion`: o ana kadarki transkript + Türkçe soru → cevap + ilgili zaman damgaları.
  - `generateMeetingNote`: tek çağrı, yapılandırılmış JSON (başlık, özet, kararlar, görevler, sözlük).
- Prompt oluşturma ve JSON ayrıştırma saf fonksiyonlardır.

**PostProcessing**
1. `.m4a` seçilen "toplantı sonrası motor" ile yeniden yazıya dökülür (`pass = final`).
2. "Diğerleri" kanalında konuşmacı ayrıştırma → `speaker1`, `speaker2`, …
   Yerelde WhisperKit paketindeki SpeakerKit (MIT, aynı bağımlılık), bulutta diarization
   destekleyen bir model.
3. `generateMeetingNote` çağrısı. Kullanıcının adı (ayarlardan) görev sahipliğini belirlemek için kullanılır.
4. Canlı transkript silinmez; ikinci geçiş ayrı saklanır.

**Storage**
- SQLite + GRDB. Ses dosyaları `~/Library/Application Support/AINotepad/Audio/`.
- Uygulama açılışında ve günde bir kez süresi dolan ses dosyaları silinir.

**Settings**
- API anahtarları Keychain'de; diğer ayarlar `UserDefaults`'ta.

**UI**
- `MenuBarExtra`: kayıt başlat/durdur, ana pencere, ayarlar.
- **Ada** (`NSPanel`, çentiğe hizalı, her zaman üstte): kayıt göstergesi + süre, algılanan dil,
  son "Diğerleri" cümlesinin Türkçesi. Hata durumunda kırmızıya döner. Çentiksiz ekranda
  (harici monitör) üst ortada hap biçiminde görünür.
- **Cam panel** (`NSPanel`, Liquid Glass, taşınabilir, boyutlanabilir, her zaman üstte):
  kaydırılabilir transkript (orijinal + Türkçe), "Ne kaçırdım?" butonu, soru kutusu.
  "Sadece Türkçe" görünümünde "Sen" bölümleri çevrilmediği için orijinal haliyle gösterilir.
  Paneldeki küçültme butonuyla gizlenir; gizliyken yalnızca ada kalır, adaya tıklayınca geri gelir.
- Ada ve panel `sharingType = .none` ile açılır. Not: macOS 15+ ScreenCaptureKit tabanlı
  yakalamalar bunu her zaman dikkate almaz; görünmezlik garanti edilmez, gerçek Zoom/Teams
  paylaşımında test edilir. Ek olarak ada + paneli birlikte gizleyen bir kısayol vardır.
- **Ana pencere**: toplantı listesi (arama ile), toplantı notu, transkript (cümleye tıklayınca
  ses o andan çalar), konuşmacıları adlandırma, Markdown dışa aktarma/kopyalama,
  sesi silme, "Tekrar işle".
- **Karşılama ekranı**: mikrofon ve sistem sesi izinlerini kontrol eder; adı, LLM sağlayıcısını
  ve anahtarı ister; WhisperKit modelini indirir.
- Kısayollar — yalnızca iki tane, aynı tuş çiftiyle, ayarlardan değiştirilebilir:
  kayıt başlat/durdur ⌃⌥R, ada + paneli göster/gizle ⌃⌥Space.

### 4.2 Toplantı durum makinesi

`idle → recording → processing → done`, ayrıca `processing → failed` ve
açılışta bulunan `recording` → `interrupted`. `failed` ve `interrupted` toplantılar
diskteki sesten "Tekrar işle" ile yeniden işlenebilir.

## 5. Veri modeli (SQLite)

```
Meeting      id, title, startedAt, endedAt, language(fi|en), status,
             audioPath?, audioExpiresAt?
Segment      id, meetingId, pass(live|final), speaker(me|others|speakerN),
             startSec, endSec, originalText, turkishText?, translationError?
SpeakerName  meetingId, speakerKey, displayName
MeetingNote  meetingId, summary, decisions[String], tasks[Task], glossary[GlossaryEntry]
Task         owner, description, dueDate?, isMine
GlossaryEntry term, meaning
```

Ayarlar: kullanıcı adı; canlı motor; toplantı sonrası motor; bulut STT URL/model;
LLM sağlayıcı/URL/model; görünüm (iki dil | sadece Türkçe); "Ne kaçırdım?" süresi (dk, varsayılan 3);
ses saklama süresi (gün, varsayılan 30); dil (Otomatik | Fince | İngilizce); kısayollar.

## 6. Hata yönetimi

- Modül başına tipli hatalar: `AudioCaptureError`, `TranscriptionError`, `LLMError`, `StorageError`.
  HTTP hataları durum kodu, yanıt gövdesi ve istek parametrelerini içerir.
- Dış API çağrıları: 3 deneme, üstel bekleme, her başarısız denemede uyarı logu, sonra son hata fırlatılır.
- Gizli yedek yok: bulut STT çökerse yerele kendiliğinden geçilmez; ada hatayı gösterir.
- Çeviri hatası yalnızca ilgili bölümü etkiler (`translationError` + tekrar dene); akış devam eder.
- Kayıt `.caf` ile çökmeye dayanıklıdır; yarıda kalan toplantı açılışta `interrupted` olur.
- Loglama: `os.Logger`, dinamik değerler yapılandırılmış alanlarda.

## 7. Test stratejisi

Swift Testing; `AINotepadCore` için `swift test`.
- **Entegrasyon (gerçek ses):** macOS `say` (Satu / Samantha sesleri) ile üretilip repoya eklenen kısa Fince ve İngilizce kayıtlar.
  WhisperKit gerçekten çalıştırılır; dil doğru algılanmalı, beklenen anahtar kelimeler geçmeli.
- **Gerçek API testleri:** LLM ve bulut STT için mock yok. Yalnızca ilgili API anahtarı ortam
  değişkeninde tanımlıysa çalışır; CI'da çalışmaz.
- **Birim testleri (az):** VAD bölümleme, dil sabitleme, prompt oluşturma, not JSON ayrıştırma.
- **Elle uçtan uca kontrol listesi:** gerçek Zoom ve Teams görüşmesi, ekran paylaşımı görünmezliği,
  çökme sonrası kurtarma.

## 8. Aşamalar

Her aşama ayrı bir uygulama planıyla yapılır ve sonunda çalışan bir uygulama bırakır.

1. **Çekirdek:** Proje iskeleti, AudioCapture, WhisperKitEngine, VAD, basit transkript paneli,
   `.caf` kaydı. Hedef: Zoom'daki Fince konuşma ekranda yazıya dökülüyor.
2. **LLM:** LLMClient'lar, canlı Türkçe çeviri, "Ne kaçırdım?", soru kutusu, ayarlar + Keychain.
3. **Toplantı sonrası:** Storage, `.m4a` dönüşümü, ikinci geçiş, diarization, not, ana pencere,
   dışa aktarma, ses saklama süresi, çökme kurtarma.
4. **Cilalama:** Ada + Liquid Glass panel, bulut STT, ekran paylaşımı gizleme, kısayollar,
   karşılama ekranı.

## 9. Riskler ve açık noktalar

- **Fince STT kalitesi:** Whisper'ın Fince doğruluğu İngilizceden düşüktür. Aşama 1'de gerçek bir
  Fince toplantı kaydıyla ölçülür; yetersizse bulut motoru varsayılan yapılabilir.
- **Ekran paylaşımı görünmezliği** garanti değildir (bkz. 4.1 UI).
- **SpeakerKit diarization kalitesi** aşama 3'te gerçek bir toplantı kaydıyla ölçülecek.
- **OpenAI uyumlu sağlayıcılar** (ör. OpenCode Go) gerçek bir çağrıyla test edilecek.
