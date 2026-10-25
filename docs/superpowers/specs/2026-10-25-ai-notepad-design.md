# AI-Notepad — Tasarım Belgesi

Tarih: 2026-10-25 · Durum: Onaylandı · Güncelleme: 2026-10-25 — hibrit STT (§2, §3, §4.1, §6–§10)

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
| Veri | Kayıtlar ve notlar yalnızca kullanıcının Mac'inde saklanır. Bulut motoru seçiliyken ses yazıya dökülmek için Deepgram ve ElevenLabs'e gönderilir (kullanıcı onayladı) |
| Konuşma tanıma | Canlı metin: **Deepgram nova-3** akışı (varsayılan) veya **WhisperKit** (Mac'te, internetsiz). Konuşmacı ayırma: **ElevenLabs Scribe v2** (toplu, kişi ayırma açık) |
| Toplantı dili | Bir toplantı tek dillidir (Fince **veya** İngilizce). Varsayılan "Otomatik", elle de seçilebilir |
| Kod stili | Veri `struct`, mantık saf fonksiyon; `actor`/`class` yalnızca dış sistem bağlayıcılarında. Yorumlar Türkçe |

**Doğrulanmış bilgi:** Apple `SpeechTranscriber` bu Mac'te (macOS 26.6) 30 dil destekliyor;
Fince ve Türkçe aralarında **yok**. Bu yüzden yerel STT motoru WhisperKit'tir.

**Ölçüm (2026-10-25, 78 sn gerçek Fince YouTube kaydı, 4 konuşmacı):**

| | Canlı kesin metin gecikmesi | Fince | Kişi ayırma |
|---|---|---|---|
| WhisperKit (Mac'te) | 3–15 sn | İyi | — |
| Deepgram nova-3 akış | medyan 0,5 sn (geçici 0,1 sn) | İyi; ilk ~11 sn kaçtı (araştırılacak) | Canlıda tutarsız |
| Deepgram nova-3 toplu | — | İyi | Herkesi tek kişi saydı |
| ElevenLabs Scribe v2 Realtime | ~2 sn | En iyi | Canlıda yok |
| ElevenLabs Scribe v2 toplu | — | En iyi | 4 konuşmacıyı doğru ayırdı |

Sonuç: canlı metin için Deepgram, konuşmacı ayırma için ElevenLabs toplu modu.

## 3. Kapsam

**Kapsamda (v1):**
- Menü çubuğu ikonu + global kısayolla elle kayıt başlatma/durdurma
- Mikrofon ("Sen") ve sistem sesi ("Diğerleri") ayrı akışlar olarak yakalama
- Canlı transkript + Türkçe çeviri; görünüm: "İki dil" veya "Sadece Türkçe"
- Otomatik dil algılama ve elle dil seçimi
- "Ne kaçırdım?" butonu (son N dk özeti, varsayılan 3) ve Türkçe soru kutusu
- Toplantı sonrası: ikinci geçiş transkripsiyon, konuşmacı ayrıştırma, yapılandırılmış not
- Not içeriği: Türkçe özet, kararlar, görevler (kullanıcınınkiler vurgulu),
  tam transkript, terimler sözlüğü, Markdown dışa aktarma/kopyalama
- Ses kaydı: varsayılan 30 gün saklanır, sonra otomatik silinir; elle de silinebilir
- Canlı STT motorları: Deepgram (bulut akış) ve WhisperKit (Mac'te); ayarlardan seçilir
- Toplantı sırasında dakikada bir konuşmacı ayırma (ElevenLabs): "Diğerleri" metni
  "Konuşmacı 1 / 2 / 3…" olarak yeniden etiketlenir
- LLM sağlayıcıları: Anthropic API ve OpenAI uyumlu API (OpenAI, Ollama ve OpenAI uyumlu
  uç nokta sunan diğer servisler)
- Arayüz: çentikteki ada + Liquid Glass cam panel + ana pencere (geçmiş) + ayarlar

**Kapsam dışı (v1):**
- Toplantıyı otomatik algılama / otomatik kayıt başlatma
- Kullanıcının toplantı sırasında kendi notlarını yazması
- Adın geçtiğinde/soru sorulduğunda uyarı
- WhisperKit seçiliyken canlı konuşmacı ayırma (yalnızca "Sen" / "Diğerleri")
- Aynı toplantıda birden fazla dil
- Windows/Linux, iOS, senkronizasyon

## 4. Mimari

```
AudioCapture ──► Transcription ──► LLM (çeviri) ──► Canlı UI (ada + cam panel)
 (mik + sistem)   (Deepgram akış /          ▲            │
     │             WhisperKit)              │            │
     ├──────────► LiveDiarization ──────────┘            │
     │            (ElevenLabs, dakikada bir)             │
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

**Transcription** — iki canlı motor, ikisi de aynı `LiveSessionEvent` olaylarını üretir:
- **Deepgram (varsayılan):** `DeepgramStreamingTranscriber`, konuşmacı akışı başına bir WebSocket
  (`wss://api.deepgram.com/v1/listen`, `model=nova-3`, `encoding=linear16`, `sample_rate=16000`,
  `interim_results=true`, `smart_format=true`). Ek kütüphane yok (`URLSessionWebSocketTask`).
  Geçici sonuçlar soluk, `is_final` sonuçlar kesin bölüm olur.
  Dil: Fince → `language=fi`, İngilizce → `language=en`, Otomatik → `language=multi`
  (Deepgram belgelerine göre Fince'yi kapsar; Fince kalitesi plan başında ölçülür, kötüyse kullanıcıya sorulur).
  Bağlantı koparsa geri çekilmeli yeniden bağlanır; arada gelen ses tamponda bekleyip sonra gönderilir.
  Yakalama sessizlikte de sürekli ses ürettiği için `KeepAlive` gerekmez.
- **WhisperKit (Mac'te):** mevcut `TranscriptionEngine` + bölümleyici + seri işçi (aşama 1).
  Model yalnızca bu motor seçiliyse yüklenir. Dil 30 sn sonra kilitlenir.

**LiveDiarization** (yalnızca Deepgram motoruyla)
- Her 60 sn'de, "Diğerleri"nin son 120 sn'si (16 kHz WAV) ElevenLabs `POST /v1/speech-to-text`
  (`model_id=scribe_v2`, `diarize=true`, `language_code=fin|eng`; Otomatik modda gönderilmez,
  ElevenLabs dili kendisi algılar) ile gönderilir.
- Ardışık pencereler 60 sn örtüşür. Örtüşen bölgedeki kelimelerin zaman çakışmasına göre yeni
  penceredeki `speaker_N` etiketleri önceki pencerenin kalıcı "Konuşmacı K" kimliklerine eşlenir;
  eşlenemeyen yeni bir kimlik alır. Eşleme saf fonksiyondur ve testlenir.
- Her "Diğerleri" bölümü, zaman aralığında en çok kelimesi olan konuşmacıyla yeniden etiketlenir
  (`LiveSessionEvent.speakersAssigned`). Etiketlenene kadar "Diğerleri" görünür.
- Bir pencere başarısız olursa hata gösterilir, bölümler "Diğerleri" kalır, sonraki pencere denenir.

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
2. "Diğerleri" kanalında tüm kayıt üzerinde konuşmacı ayrıştırma → `speaker1`, `speaker2`, …
   Bulutta ElevenLabs Scribe v2; yerelde WhisperKit paketindeki SpeakerKit (MIT, aynı bağımlılık).
3. `generateMeetingNote` çağrısı. Kullanıcının adı (ayarlardan) görev sahipliğini belirlemek için kullanılır.
4. Canlı transkript silinmez; ikinci geçiş ayrı saklanır.

**Storage**
- SQLite + GRDB. Ses dosyaları `~/Library/Application Support/AINotepad/Audio/`.
- Uygulama açılışında ve günde bir kez süresi dolan ses dosyaları silinir.

**Settings**
- API anahtarları Keychain'de (servis `AINotepad`, hesaplar `deepgram`, `elevenlabs`); diğer ayarlar
  `UserDefaults`'ta. Ayarlar penceresi: iki anahtar alanı (gizli giriş) ve canlı motor seçimi.
- Seçili motorun anahtarı yoksa kayıt başlatılmaz; menü ve panel açık Türkçe hata gösterir.

**UI**
- `MenuBarExtra`: kayıt başlat/durdur, ana pencere, ayarlar.
- **Ada** (`NSPanel`, çentiğe hizalı, her zaman üstte): kayıt göstergesi + süre, algılanan dil,
  son "Diğerleri" cümlesinin Türkçesi. Hata durumunda kırmızıya döner. Çentiksiz ekranda
  (harici monitör) üst ortada hap biçiminde görünür.
- **Cam panel** (`NSPanel`, Liquid Glass, taşınabilir, boyutlanabilir, her zaman üstte):
  kaydırılabilir transkript (orijinal + Türkçe), "Ne kaçırdım?" butonu, soru kutusu.
  "Sadece Türkçe" görünümünde "Sen" bölümleri çevrilmediği için orijinal haliyle gösterilir.
  Paneldeki küçültme butonuyla gizlenir; gizliyken yalnızca ada kalır, adaya tıklayınca geri gelir.
- "Ekran görüntülerinde ve kayıtlarda gizle" ayarı (varsayılan açık) `sharingType = .none` uygular.
  Ölçüm: macOS 26'da sistem ekran görüntüsü bunu dikkate almadı, panel görüntüde çıktı. Görünmezlik
  garanti edilmez; asıl güvence ada + paneli birlikte gizleyen kısayoldur.
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

Ayarlar: kullanıcı adı; canlı motor (Deepgram | Mac'te); Deepgram ve ElevenLabs anahtarları;
LLM sağlayıcı/URL/model; görünüm (iki dil | sadece Türkçe); "Ne kaçırdım?" süresi (dk, varsayılan 3);
ses saklama süresi (gün, varsayılan 30); dil (Otomatik | Fince | İngilizce); kısayollar.

## 6. Hata yönetimi

- Modül başına tipli hatalar: `AudioCaptureError`, `TranscriptionError`, `LLMError`, `StorageError`.
  HTTP hataları durum kodu, yanıt gövdesi ve istek parametrelerini içerir.
- Dış API çağrıları: 3 deneme, üstel bekleme, her başarısız denemede uyarı logu, sonra son hata fırlatılır.
- Gizli yedek yok: bulut STT çökerse yerele kendiliğinden geçilmez; ada hatayı gösterir.
- Deepgram bağlantısı koparsa geri çekilmeli 4 deneme; tükenirse o akış biter ve panelde
  hata görünür. Ses kaydı her durumda diske yazılmaya devam eder.
- ElevenLabs penceresi başarısızsa yalnızca o pencere etkilenir; panelde hata, sonraki pencere denenir.
- Çeviri hatası yalnızca ilgili bölümü etkiler (`translationError` + tekrar dene); akış devam eder.
- Kayıt `.caf` ile çökmeye dayanıklıdır; yarıda kalan toplantı açılışta `interrupted` olur.
- Loglama: `os.Logger`, dinamik değerler yapılandırılmış alanlarda.

## 7. Test stratejisi

Swift Testing; `AINotepadCore` için `swift test`.
- **Entegrasyon (gerçek ses):** macOS `say` (Satu / Samantha sesleri) ile üretilip repoya eklenen kısa Fince ve İngilizce kayıtlar.
  WhisperKit gerçekten çalıştırılır; dil doğru algılanmalı, beklenen anahtar kelimeler geçmeli.
- **Gerçek API testleri:** LLM ve bulut STT için mock yok. Anahtarlar Keychain'den (`AINotepad`)
  okunur; yalnızca `AINOTEPAD_CLOUD_TESTS=1` ile çalışır; CI'da çalışmaz. Gerçek Fince ses:
  repoya eklenen kısa, çok konuşmacılı bir kayıt.
- **Birim testleri (az):** VAD bölümleme, dil sabitleme, prompt oluşturma, not JSON ayrıştırma.
- **Elle uçtan uca kontrol listesi:** gerçek Zoom ve Teams görüşmesi, ekran paylaşımı görünmezliği,
  çökme sonrası kurtarma.

## 8. Aşamalar

Her aşama ayrı bir uygulama planıyla yapılır ve sonunda çalışan bir uygulama bırakır.

1. **Çekirdek** ✅ (main'de): Proje iskeleti, AudioCapture, WhisperKitEngine, VAD, basit panel,
   `.caf` kaydı, konuşmacı blokları, kopyalama, ekran görüntüsü ayarı.
2. **Hibrit STT:** Deepgram akış motoru, ElevenLabs ile dakikalık konuşmacı ayırma, Ayarlar penceresi
   + Keychain, motor seçimi. Hedef: Fince metin ~1 sn'de, konuşmacılar ~1–2 dk'da ayrılmış.
3. **Arayüz tasarımı:** Kurumsal, sade ve lüks görünüm: çentikteki ada + Liquid Glass panel, menü,
   ayarlar; tipografi, renk, boşluk sistemi; kısayollar. Önce mockup ile yön seçilir.
4. **LLM:** LLMClient'lar, canlı Türkçe çeviri, "Ne kaçırdım?", soru kutusu.
5. **Toplantı sonrası:** Storage, `.m4a` dönüşümü, tüm kayıtta konuşmacı ayırma, not, ana pencere,
   konuşmacılara isim verme, dışa aktarma, ses saklama süresi, çökme kurtarma, karşılama ekranı.

## 9. Riskler ve açık noktalar

- **Deepgram `language=fi` ilk saniyeler:** ikinci ölçümde nedeni bulundu — model kaydın ilk 13 sn'si
  için boş kesin sonuç döndürüyor (kısa, hızlı çocuk konuşması); bağlantı sorunu değil. Aynı kayıtta
  `language=multi` bu kısmı yakaladı ve genel kalitesi `fi` kadar iyiydi (tek örnek). Otomatik (varsayılan)
  mod `multi` kullanır.
- **`multi` geçici sonuçları** kısa süre başka dil/yazı gösterebilir (ölçümde ilk geçici kelime Farsça);
  kesin sonuçlar Fince'ydi. Geçici metin soluk gösterildiği için kabul edilir.
- **Konuşmacı eşleme hataları:** pencereler arası eşleme yanlışsa bir kişi iki numara alabilir;
  toplantı sonrası tüm kayıt üzerinden yapılan ayırma kesin sonucu verir.
- **Maliyet:** iki Deepgram akışı ~0,6–0,9 $/sa + ElevenLabs (örtüşme nedeniyle sesin ~2 katı)
  ~0,45 $/sa → toplam ~1–1,4 $/sa (fiyatlar ikincil kaynaklardan; kendi hesaplarında doğrulanmalı).
- **Ekran paylaşımı görünmezliği** garanti değildir (bkz. 4.1 UI).
- **SpeakerKit (yerel) konuşmacı ayırma kalitesi** aşama 5'te ölçülecek.
- **OpenAI uyumlu sağlayıcılar** (ör. OpenCode Go) gerçek bir çağrıyla test edilecek.
