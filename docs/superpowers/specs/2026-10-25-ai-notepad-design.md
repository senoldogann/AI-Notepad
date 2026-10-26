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
                 (2. geçiş STT + diarization + not)  (JSON)     (geçmiş, not, dışa aktarma)
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
  saatleri farklı olduğu için akışlar ayrı dosyalarda tutulur (toplantı bitince ayrı `.m4a`'lar).
- İki akış kaydın başladığı ana hizalanır (`clockAlignedStream`): geç başlayan akış (izin penceresi) ve cihaz
  değişiminde yakalama yeniden kurulurken oluşan 0,5 sn'den uzun boşluklar sessizlikle doldurulur; böylece "Sen"
  ve "Diğerleri" aynı zaman çizgisinde kalır.
- Ses thread'indeki tekrarlayan hata logları dakikada bire seyreltilir.
- **Yankı filtresi:** hoparlörden mikrofona giren ses "Sen" altında tekrar yazılır. Bir "Sen" bölümü, ±3 sn içindeki
  "Diğerleri" metniyle boşluksuz harf üçlüleri üzerinden karşılaştırılır (en az %60 ortak → yankı). Kelime
  karşılaştırması gerçek toplantıda kaçırdı: iki tanıyıcı Fince bileşik kelimeyi ve ekleri farklı böldü
  ("lehdistä tilaisuuteen" ↔ "lehdistötilaisuuteen", "kaudelle" ↔ "hallituskaudelle"). Filtre canlı panelde,
  Toplantılar sayfasında, notta ve dışa aktarmada aynı şekilde uygulanır; saklanan veri değişmez.
- STT/LLM'den tamamen bağımsızdır: aşağı akıştaki hiçbir hata kaydı durdurmaz.

**Transcription** — iki canlı motor, ikisi de aynı `LiveSessionEvent` olaylarını üretir:
- **Deepgram (varsayılan):** `DeepgramStreamingTranscriber`, konuşmacı akışı başına bir WebSocket
  (`wss://api.deepgram.com/v1/listen`, `model=nova-3`, `encoding=linear16`, `sample_rate=16000`,
  `interim_results=true`, `smart_format=true`). Ek kütüphane yok (`URLSessionWebSocketTask`).
  Geçici sonuçlar soluk, `is_final` sonuçlar kesin bölüm olur.
  Dil: Fince → `language=fi`, İngilizce → `language=en`. Otomatik: kayıt `fi` ile başlar; ilk konuşmacı
  ayırma penceresinin (15. sn) ElevenLabs dil sonucu olasılık ≥ 0,8 ile `eng` ise iki akış `en`'e geçer
  (yeniden bağlanma yolu), `fin` ise Fince kalır; dil kilitlenir. Güvensizse sonraki pencere denenir.
  (`multi` ölçümde güvenilmez çıktı: sentetik Fince diyaloğu Norveççe sandı; kullanıcı bu yolu seçti.)
  Bağlantı koparsa geri çekilmeli yeniden bağlanır (~120 sn bütçe, en fazla 5 sn bekleme); arada gelen ses ve
  kesinleşmemiş gönderilmiş ses bağlanınca sırasıyla yeniden gönderilir. Kapanışta süren yeniden bağlanma
  (en fazla 5 sn) beklenir ki kuyruktaki son ses gönderilsin.
  Yakalama sessizlikte de sürekli ses ürettiği için `KeepAlive` gerekmez.
- **WhisperKit (Mac'te):** mevcut `TranscriptionEngine` + bölümleyici + seri işçi (aşama 1).
  Model yalnızca bu motor seçiliyse yüklenir. Dil 30 sn sonra kilitlenir. Bölümleyici konuşmadan önceki sessiz
  çerçeveyi (100 ms) bölümün başına ekler ki ilk hece kesilmesin; bu ön-kayıt konuşma süresine sayılmaz.
- **Toplantı ortasında dil değişimi:** oturum `LiveSessionHandle` döndürür; kullanıcı kayıt sırasında dili
  (menü, panelin dil çipi ya da adanın sağ tık menüsü) değiştirirse bulutta iki Deepgram akışı, WhisperKit'te
  sonraki işler o andan itibaren yeni dille yapılır ve dil kilitlenir (otomatik algılama artık değiştirmez).

**LiveDiarization** (yalnızca Deepgram motoruyla)
- İlk pencere 15. sn'de (dil algılama için erken), sonra her 60 sn'de, "Diğerleri"nin son 120 sn'si (16 kHz WAV) ElevenLabs `POST /v1/speech-to-text`
  (`model_id=scribe_v2`, `diarize=true`, `language_code=fin|eng`; Otomatik modda gönderilmez,
  ElevenLabs dili kendisi algılar) ile gönderilir.
- Ardışık pencereler 60 sn örtüşür. Örtüşen bölgedeki kelimelerin zaman çakışmasına göre yeni
  penceredeki `speaker_N` etiketleri önceki pencerenin kalıcı "Konuşmacı K" kimliklerine eşlenir;
  eşlenemeyen yeni bir kimlik alır. Eşleme saf fonksiyondur ve testlenir.
- Her "Diğerleri" bölümü, zaman aralığında en çok kelimesi olan konuşmacıyla yeniden etiketlenir
  (`LiveSessionEvent.speakersAssigned`). Etiketlenene kadar "Diğerleri" görünür.
- Bir pencere başarısız olursa hata gösterilir, bölümler "Diğerleri" kalır, sonraki pencere denenir.

**LLM**
- Sağlayıcıdan bağımsız `LLMRequest` (`tier: fast | smart`) + `sendLLM(provider:request:)`; `LLMProvider` =
  Anthropic ya da OpenAI uyumlu (temel adres + hızlı/akıllı model + isteğe bağlı anahtar). Ayrıntı §4.4.
- Görevler (her biri ayrı, tek amaçlı fonksiyon):
  - `translateSegment`: yalnızca "Diğerleri"nin kesin bölümleri; son birkaç bölüm bağlam olarak eklenir.
  - `summarizeRecent`: son N dk → *konu*, *kararlar*, *senden istenenler*.
  - `answerQuestion`: o ana kadarki transkript + Türkçe soru → cevap + ilgili zaman damgaları.
  - `generateMeetingNote`: tek çağrı, yapılandırılmış JSON (başlık, özet, kararlar, görevler, sözlük).
- Prompt oluşturma ve JSON ayrıştırma saf fonksiyonlardır.

**PostProcessing** (aşama 5; kayıt bitince otomatik, "Tekrar işle" ile elle)
1. `me.caf` ve `others.caf` ayrı ayrı AAC `.m4a`'ya (16 kHz mono) dönüştürülür, `.caf`'ler silinir.
   (İki kanallı birleştirme yapılmaz: cihaz saatleri farklı, ayrı dosyalar daha sağlam.)
2. Son geçiş kaydın motoruna göre (`MeetingRecord.engine`; yerel toplantı buluta gönderilmez), dil kaydın
   kilitlenmiş dilidir (yoksa otomatik):
   - **Bulut:** `others.m4a` tek istekle ElevenLabs Scribe v2'ye (`diarize=true`); zaman aşımı en az 300 sn,
     kaydın her dakikası için +10 sn.
   - **Yerel (internetsiz):** `others.m4a` canlıdaki WhisperKit modeliyle (large-v3 turbo, ayrı örnek; canlı motor
     meşgul edilmez) VAD parçalı, kelime zamanlı yazıya dökülür; SpeakerKit (Pyannote) konuşmacı dönemlerini verir;
     her kelime en çok örtüştüğü (yoksa en yakın) dönemin konuşmacısını alır.
   Kelimeler konuşmacı değişiminde ya da 1,5 sn'den uzun boşlukta kesin bölümlere ayrılır ("Konuşmacı N").
   "Sen" için canlı bölümler kullanılır. Son geçiş yapılamazsa (anahtar yok, `others` sesi yok) toplantıda
   uyarı (`notice`) görünür ve not canlı transkriptten üretilir.
3. Not: seçili LLM'in akıllı modeli (Claude Opus), yapılandırılmış çıktı `{baslik, ozet, kararlar[], gorevler[{sahip, aciklama, tarih?, benimMi}],
   sozluk[{terim, anlam}]}`. Kullanıcının adı (Ayarlar) ve "Sen" etiketi görev sahipliği için verilir.
4. Canlı transkript silinmez; son geçiş ayrı saklanır. Bir adım başarısızsa toplantı `failed` olur, hata
   saklanır; ses dosyaları kaldığı için "Tekrar işle" mümkündür.

**Storage**
- Her toplantı kendi oturum klasöründe: `Sessions/<yyyyMMdd-HHmmss>/meeting.json` + `me.m4a`, `others.m4a`.
  SQLite + GRDB yerine JSON seçildi: tek kullanıcı, en fazla birkaç yüz toplantı; ek bağımlılık yok, elle
  okunabilir, bozulma tek toplantıyla sınırlı; arama bellekte. Yazma atomik (`.atomic`).
- Saklama süresi (Ayarlar, 7–365 gün, varsayılan 30) dolan ses dosyaları açılışta, saatte bir ve Toplantılar
  penceresi açılınca silinir; kayıttaki/işlenen toplantı atlanır; metin ve not kalır.
- Kayıt sonrası bellekteki toplantı listesi yerinde güncellenir (her kayıtta tüm klasörler yeniden okunmaz).
- Açılışta `recording` ya da `processing` durumunda kalmış toplantı `interrupted` olur.

**Settings**
- API anahtarları Keychain'de (servis `AINotepad`, hesaplar `deepgram`, `elevenlabs`, `anthropic`, `openai`);
  diğer ayarlar `UserDefaults`'ta. Anahtarlar arka planda okunur (izin penceresi arayüzü dondurmaz);
  `security` ile eklenmiş öğe için ilk okumada macOS izin sorar ("Her Zaman İzin Ver"). Öğeyi uygulamaya
  devretmek (sil + yeniden ekle) seçilmedi: Terminal'den okuyan bulut testleri izin penceresinde takılırdı.
- Ayarlar penceresi sekmeli: Genel (motor, ad, görünüm, "Ne kaçırdım?" süresi 1–10 dk, ses saklama süresi),
  LLM (sağlayıcı, adres, modeller, anahtar, "Bağlantıyı dene"), Anahtarlar (Deepgram, ElevenLabs), Kısayollar
  (kaydedici).
- Seçili motorun anahtarları yoksa kayıt başlatılmaz; eksiklerin hepsi birlikte bildirilir. Eksik anahtar/ayar
  ve kısayol hataları kayıt başlamadan menüde kırmızı satır olarak görünür. Kayıt sırasında anahtar kaydedilirse
  çeviri yeni anahtarla sürer.

**UI**
- **Arayüz dili:** Türkçe (kaynak) ve İngilizce; `App/Localizable.xcstrings` (String Catalog, kaynak dil `tr`) ve
  `App/InfoPlist.xcstrings` (izin metinleri). Ayarlar › Genel › Arayüz dili: Sistem / Türkçe / English — uygulamanın
  `AppleLanguages` tercihine yazılır, "Şimdi yeniden başlat" ile uygulanır (kayıt sürerken kapalı). Çekirdekteki
  kullanıcı metinleri `String(localized:)` ile ana paketten çevrilir; tarihler arayüz diline göre biçimlenir. LLM
  istemleri, toplantı notu ve canlı çeviri her zaman Türkçedir; istemdeki konuşmacı etiketleri arayüz dilinden
  bağımsızdır (`promptSpeakerLabel`). Katalogdaki her metnin İngilizcesi ve aynı yer tutucuları bir testle denetlenir.
- **Görünüm ayarları** (Ayarlar › Görünüm, panelde anında): tema (Sistem/Açık/Koyu), vurgu rengi (5), panel arka planı
  (cam / koyu cam / opak), yazı tipi (SF Pro, SF Rounded, New York, SF Mono), metin boyutu (11–24 pt), satır aralığı,
  transkript alt boşluğu, ada açık/kapalı; "varsayılana döndür". Değerler `PanelAppearance` ortam değeriyle tüm panel
  sayfalarına (canlı transkript, asistan kartı, toplantı sayfası) ulaşır.
- **Canlı metni izleme:** transkript en alttayken yeni ve büyüyen metni kendiliğinden izler; kullanıcı yukarı kaydırdıysa
  yerinde kalır ve "Yeni metin ↓" düğmesi çıkar. En altta ayarlanabilir boşluk vardır.
- **İpuçları:** panel uygulamayı öne getirmediği için sistem ipuçları görünmez; düğmelerin üzerine gelince 0,45 sn sonra
  panelin içinde çizilen ipucu çıkar (kenardaki düğmelerde taşmayacak hizada).
- **Panel köşeleri:** pencere içeriği panel yarıçapıyla maskelenir ve gölge içerik çizildikten sonra yeniden hesaplanır;
  köşeler saydam, gölge ve kenar yuvarlak (önceden üst köşelerde dikdörtgen kenar görünüyordu).
- **Ada (açık hâl):** konuşmacı (renkli nokta + ad), son en fazla iki cümlenin Türkçesi (14 pt, iki satır) ve altında
  çevirisi beklenen en yeni orijinal metin (canlı, soluk, tek satır; "İki dil"de çevrilenlerin orijinali); hata varsa
  alt satır hatadır. "Sadece orijinal"de ana satır orijinaldir. Parça parça birleştirme ve ortadan kısaltma yok.
- **Kayıt sırasında konuşmacı düzeltme:** paneldeki "Diğerleri/Konuşmacı N" etiketine tıklayınca "Bu bölümü ata"
  (başka konuşmacı ya da yeni konuşmacı) ve "Tümünü birleştir" (bu konuşmacının geçmiş ve gelecek tüm bölümleri).
  Düzeltmeler otomatik ayırmanın sonraki atamalarının üstüne uygulanır; görünüm, "Ne kaçırdım?"/soru ve kaydedilen canlı
  transkript düzeltilmiş hâli kullanır. Son geçiş konuşmacıları kaydın tamamından yeniden ayırır; toplantı sayfasında
  iki konuşmacı birleştirilebilir (adı taşınır).
- **Toplantı sayfası sekmeleri:** "Özet" (görevler, özet, kararlar, sözlük) ve "Transkript" (konuşmacı adları ve
  birleştirme, paragraflı transkript). Not varsa sayfa Özet'te açılır.
- **Oynatıcı (Spotify tarzı):** "Dinle" ya da paragrafa tıklama; "Sen" ve "Diğerleri" kayıtları aynı zaman çizgisinde
  birlikte çalar. Altta cam kart: çalan konuşmacı ve sözü, konum çubuğu ve süreler, 10 sn geri / oynat-duraklat /
  10 sn ileri, hız (1×, 1,25×, 1,5×, 2×, 0,75×), kapat. Transkript şarkı sözü gibi akar: çalan paragraf vurgulu ve
  ortaya kaydırılır; söylenen kelimeler parlak, o anki kelime vurgu renginde, gelecekler soluk. Kelime zamanları son
  geçişten (ElevenLabs ya da WhisperKit) saklanır (`StoredSegment.words`); olmayan bölümlerde harf sayısıyla tahmin.
- **Duyarlı düzen (en küçük 340×300 pt):** panel başlığında genişlik daraldıkça önce Kopyala/Toplantılar/Ayarlar, çok
  darda dil çipi "⋯" menüsüne toplanır (kayıt denetimleri ve gizle hep görünür; durum metni en son kısalır);
  "Ne kaçırdım?" simgeye döner; toplantı sayfası düğmeleri alt satıra akar (`FlowLayout`); Ayarlar sekmeleri sığmazsa
  açılır seçici olur; alt sayfa başlıklarında geri ve "Kayıtta" yalnızca simge olur; hazırlanma kartı kısa panelde
  simge ve açıklamasını bırakır; uzun asistan cevabı kartın içinde kaydırılır. Panel küçük ekranda ekrana sığacak
  boyutta açılır, ekran değişince görünür alanın içine çekilir (`clampedPanelFrame`).
- **Tek pencere:** uygulamanın tek penceresi cam paneldir. Ayarlar, Toplantılar, toplantı ayrıntısı ve Kurulum
  panelin sayfalarıdır (ayrı pencere, açılır kayıt penceresi ya da uyarı penceresi yok); alt sayfalarda geri düğmesi
  ve kayıt sürüyorsa canlı metne tek dokunuşla dönüş vardır.
- **Panel başlığı:** durum, dil çipi (kayıtta dokununca dil değişir), kayıt denetimleri — kayıt yokken "Başlat";
  kayıtta Duraklat/Devam, Mikrofon aç/kapat, Bitir — ve Kopyala, Toplantılar, Ayarlar, Gizle.
- **Duraklat:** iki akış sessizlikle değiştirilir (kayıt sürer, metin üretilmez, zaman çizgisi bozulmaz); durum
  "Duraklatıldı". **Mikrofonu kapat** ("yalnızca dinliyorum"): "Sen" sessizliğe çevrilir; hoparlörle dinlerken
  yankıyı kökten önler; tercih saklanır (Ayarlar › Genel › Mikrofon).
- `MenuBarExtra`: kaydı başlat/bitir, duraklat/devam ("Bitiriliyor…" sırasında kapalı), ada + panel, kırmızı kurulum
  sorunları, dil (kayıtta "Dili değiştir"), ekran görüntüsünde gizle, Toplantılar, Ayarlar, Kurulum (panel
  sayfalarını açar), Çık.
- **Bitiriliyor durumu:** durdurmadan oturum bitene kadar (son metin, bekleyen çeviriler en fazla 10 sn, son
  konuşmacı ayırma) menü, panel ve ada "Bitiriliyor…" gösterir; yeni kayıt başlatılamaz.
- **Hazırlanma kartı:** Bitir'den toplantı işlenene kadar panelin içeriği bulanıklaşır, ortada animasyonlu kart durur:
  adımlar (kayıt bitiriliyor → ses kaydı hazırlanıyor → kaydın tamamı işleniyor / yerelde konuşmacılar Mac'te
  ayrılıyor → not hazırlanıyor; biten ✓, süren gösterge, bekleyen soluk), ilerleme çubuğu, "Arka planda devam et".
  Adımlar işleme sürecinden gelir (`processMeeting(onStep:)`). Bitince kart kaybolur, toplantı sayfası görünür.
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
- **Toplantılar sayfası:** arama, yeniden eskiye liste (sana düşen görev sayısı yıldızla). **Toplantı sayfası**
  (kayıt bitince panel kendiliğinden açar; asıl amaç toplantı sonunda ne yapılacağını bilmek): işleniyor durumu,
  hata/uyarı, **önce "Senin görevlerin" vurgulu kartı**, sonra özet, kararlar, diğer görevler, sözlük, konuşmacı
  adları ve paragraflı transkript (aynı konuşmacının art arda bölümleri tek paragraf, 60 sn'yi geçince yeni paragraf;
  yankı süzülmüş; altında Türkçesi). Zaman damgasına tıklayınca ilgili kayıt — "Sen" için `me`, diğerleri için
  `others` — o andan 0,3 sn önce çalar; çalan paragraf vurgulanır; altta cam çalma çubuğu. Ses silinmişse, toplantı
  kayıtta ya da işlemedeyse çalma düğmesi yok. Eylemler: PDF, Markdown, Kopyala, Notu yenile, Tekrar işle, Sesi sil.
- **Dışa aktarma:** PDF ve Markdown doğrudan İndirilenler'e (`<başlık> <yyyy-MM-dd>.pdf`, aynı ad varsa numaralı)
  kaydedilir, sayfada "kaydedildi · Finder'da göster" satırı çıkar. PDF: A4, Helvetica Neue (sistem yazı tipi PDF'te
  kopyalanınca harfleri bozuyordu), başlık + tarih/süre/dil, Senin görevlerin, Özet, Kararlar, Diğer görevler,
  Sözlük, paragraflı transkript (Türkçesi italik), her sayfada "Sayfa N / M".
- **Kurulum sayfası** (ilk açılışta bir kez panelde; kapatılsa da tekrar açılmaz; menüde "Kurulum"): hoş geldin → izinler (mikrofon durumu +
  izin iste; sistem sesi için 2 sn deneme yakalamasıyla macOS izin penceresi, macOS bu iznin durumunu
  sorgulatmadığı için açık metin; reddedildiyse Sistem Ayarları kısayolu) → ad + motor → anahtarlar → kısayollar.
- Kısayollar — yalnızca iki tane, aynı tuş çiftiyle, ayarlardan değiştirilebilir (değişince eskisi bırakılır;
  yalnızca ⇧ ya da değiştiricisiz harf, sistem kısayolu, diğer eylemin kısayolu ya da başka uygulamanın kısayolu
  reddedilir ve eski kısayol çalışmaya devam eder):
  kayıt başlat/durdur ⌃⌥R, ada + paneli göster/gizle ⌃⌥P (⌃⌥Space macOS'ta giriş kaynağı kısayolu olduğu için kullanılmaz).

### 4.3 Görsel tasarım (aşama 3)

**İlke:** kurumsal, temiz, anlaşılır, lüks-sade. Tek vurgu rengi, bol boşluk, SF Pro, Liquid Glass yüzeyler;
süs, gölge oyunu ve gereksiz ikon yok. Bilgi hiyerarşisi: metin > konuşmacı > durum.

**Tasarım ölçüleri (`DesignTokens`):** boşluk 4/8/12/16/24; köşe yarıçapı panel 22, çip 10;
yazı: metin 14 pt regular (satır aralığı 4), konuşmacı etiketi 11 pt semibold büyük harf (harf aralığı 0,6),
durum 12 pt medium, rakamlar tek aralıklı. Geçici metin %55 opaklık. "Sen" vurgu rengi `#3B5BDB`;
kişi renkleri sırayla `#0CA678`, `#F08C00`, `#D6336C`, `#7048E8`, `#1098AD`, `#5C940D` (7. kişiden itibaren
başa döner). Hata: sistem kırmızısı, %12 dolgulu ince bant.

**Ada:** yalnızca kayıt sırasında görünür. Çentikli ekranda çentiğe yapışık siyah ada: yükseklik
`safeAreaInsets.top`, genişlik çentik + 2×120 pt; sol kanatta kırmızı nokta + süre, sağ kanatta dil.
Fare üstüne gelince yay animasyonuyla aşağı açılır (+64 pt) ve son "Diğerleri" cümlesini 2 satırda gösterir.
Tıklama paneli aç/kapa yapar. Çentiksiz ekranda menü çubuğunun 8 pt altında ortada aynı içerikli siyah hap.

**Cam panel:** kenarlıksız, arka planından taşınabilir, boyutlanabilir `NSPanel`; içerik
`.glassEffect(.regular, in: .rect(cornerRadius: 22))`. Üst satır: durum (kayıt noktası + süre ya da "Hazır"),
dil çipi, kopyala ve küçült düğmeleri. Gövde: konuşmacı blokları (renk noktası + etiket + akan metin).
Alt: en son 3 hata ince kırmızı bantta.

**Yapı:** görünümler yeni `AINotepadUI` paket hedefinde ve yalnızca değer tipi `LiveViewState` +
eylem kapanışlarıyla beslenir (uygulama modeline bağlı değil). Görsel kontrol için geliştirme aracı
`AINotepadPreview` (uygulamaya girmez) ada ve paneli örnek verilerle gerçek pencerelerde açar; görüntü
`screencapture -l` ile alınır (`ImageRenderer` cam efektini çizemiyor).
Etiketler nötr renkte, kişi rengi yalnızca noktada (camda okunaklılık). Ada hata olunca sağ kanatta kırmızı uyarı
gösterir, açık hâlde cümlenin altında tek satır hata; sağ tık menüsünde "Kaydı durdur". Panel başlığında kayıt
sırasında durdur düğmesi.

**Kısayollar:** ⌃⌥R kayıt başlat/durdur, ⌃⌥P ada + panel göster/gizle (Carbon `RegisterEventHotKey`, özel kayıt;
erişilebilirlik izni gerektirmez). Etkin bir macOS sistem kısayoluyla ya da başka uygulamayla çakışan kısayol
kaydedilmez ve menüde adıyla bildirilir.

### 4.4 LLM (aşama 4)

**Sağlayıcı:** varsayılan Anthropic Claude, ham HTTP `POST https://api.anthropic.com/v1/messages`
(Swift için resmi SDK yok), başlıklar `x-api-key`, `anthropic-version: 2026-10-21`. Anahtar Keychain'de
(`AINotepad` / `anthropic`). İkinci seçenek **OpenAI uyumlu** (OpenAI, Ollama, OpenCode Go…):
`POST {temel adres}/chat/completions`, `Authorization: Bearer` (anahtar yoksa gönderilmez), sistem + kullanıcı
mesajı, `max_completion_tokens`, şema varsa katı `response_format: json_schema`. Ölçüm: Ollama'daki model
`response_format`'ı uygulamadı (Markdown döndü), bu yüzden şema sistem mesajında da verilir. Çeviri hızlı modelle,
diğerleri akıllı modelle (ikisi Ayarlar'dan).

**Model ve effort seçimi (Ayarlar › LLM):** Claude'da "Canlı çeviri" ve "Ne kaçırdım?, soru ve not" için ayrı model
(Haiku 5.5, Sonnet 5.5, Opus 5.5, Fable 5.1) ve effort (low…max); varsayılan Haiku/low ve Opus/medium. Modellerin
parametre kuralları (her biri gerçek API'de doğrulandı): hızlı sınıfta düşünme Haiku 5.5'te `disabled`, Sonnet 5.5'te
`between_tools` ile kapatılır (yalnızca effort ≤ high; üstünde 400); Opus 5.5 ve Fable 5.1'de kapatılamaz (alan
gönderilmez). Sunucu tarafı yedek (`fallbacks: "default"`) Haiku 5.5 dışındaki modellerde. OpenAI uyumlu sağlayıcıda
effort isteğe bağlı `reasoning_effort` (low/medium/high ya da gönderme).

**Modeller:** canlı cümle çevirisi `claude-haiku-5-5` (düşünme kapalı, `effort: low`; hız ve maliyet —
saatte birkaç sent); "Ne kaçırdım?" ve soru-cevap `claude-opus-5-5` (`effort: medium`, `fallbacks: "default"` +
`anthropic-beta: server-side-fallback-2026-07-01`). Her yanıtta `stop_reason == "refusal"` önce denetlenir.

**Canlı çeviri:** yalnızca "Diğerleri"nin kesin bölümleri, sırayla (tek seri kuyruk), önceki 3 kesin bölüm
bağlam olarak. Panel her bloğun altında Türkçesini gösterir; görünüm ayarı "İki dil" (orijinal soluk + Türkçe),
"Sadece Türkçe" ya da "Sadece orijinal" (Fince/İngilizce; bu görünümde canlı çeviri yapılmaz — maliyet; toplantı
sonu Türkçe not yine üretilir; görünüm değişince sonraki cümleler çevrilir). Adanın son cümlesi varsa Türkçesidir. Çeviri hatası panelde tek satır (tekilleştirilmiş).

**"Ne kaçırdım?":** son 3 dk transkripti (`[mm:ss] Etiket: metin`) → yapılandırılmış çıktı
(`output_config.format` JSON şeması) `{konu: String, kararlar: [String], sendenIstenenler: [String]}`;
panelde kapatılabilir kart.

**Soru kutusu:** panel altında metin alanı; o ana kadarki transkript + Türkçe soru → Türkçe kısa cevap,
ilgili anların zaman damgalarıyla. Panel metin girişi için anahtar pencere olabilen `NSPanel` alt sınıfıdır.

**Güvenlik:** transkript tüm istemlerde etiketlidir (`<transkript>`, `<cumle>`, `<baglam>`) ve sistem istemi
etiket içindeki metnin veri olduğunu, içindeki talimatların uygulanmayacağını söyler. Henüz konuşma yokken soru
LLM'e gönderilmez, yerelde cevaplanır.

**Çeviri hatası:** bölüm "çeviri alınamadı" olarak işaretlenir; panelde bloğun altında "Tekrar dene" (sağlayıcı
yeniden çözülür). Çevirisi beklenen en yeni "Diğerleri" metni adada orijinal haliyle soluk görünür (eski Türkçe
onu gizlemez). Kayıt bitince bekleyen çeviriler en fazla 10 sn beklenip toplantıya yazılır.

**Hatalar:** 408/429/5xx/ağ hatası 3 deneme (`retry-after` saniyesine uyulur, en fazla 30 sn; yoksa 1, 2 sn; uyarı
logu), diğer 4xx denenmez; 200 içinde reddetme, `max_tokens`/`length` kesilmesi (`LLMError.truncated`), bozuk ve
boş yanıt kesin hatadır. `LLMError.http` durum kodu, gövde, model ve istek kimliğini (`request-id` /
`x-request-id`) içerir, anahtar içermez; gövde yalnızca özel (private) loglanır.

### 4.2 Toplantı durum makinesi

`idle → recording → processing → done`, ayrıca `processing → failed` ve
açılışta bulunan `recording` → `interrupted`. `failed` ve `interrupted` toplantılar
diskteki sesten "Tekrar işle" ile yeniden işlenebilir.

## 5. Veri modeli (`meeting.json`)

```
MeetingRecord  id (klasör adı), title, startedAt, endedAt?, language?, status (recording|processing|done|failed|interrupted),
               failureMessage?, liveSegments[StoredSegment], finalSegments[StoredSegment],
               translations{segmentKey: Türkçe}, speakerNames{kişi: ad}, note?, audioDeleted,
               engine? (cloud|local; eski toplantılarda yok = bulut), notice? (ör. son geçiş atlandı)
StoredSegment  key ("others-3"), speaker (me|others), person?, startSec, endSec, text
MeetingNote    title, summary, decisions[String], tasks[NoteTask], glossary[GlossaryEntry]
NoteTask       owner, description, dueDate?, isMine
GlossaryEntry  term, meaning
```

Ayarlar: kullanıcı adı; canlı motor (Deepgram | Mac'te); Deepgram ve ElevenLabs anahtarları;
LLM sağlayıcı/URL/model; görünüm (iki dil | sadece Türkçe); "Ne kaçırdım?" süresi (dk, varsayılan 3);
ses saklama süresi (gün, varsayılan 30); dil (Otomatik | Fince | İngilizce); kısayollar.

## 6. Hata yönetimi

- Modül başına tipli hatalar: `AudioCaptureError`, `TranscriptionError`, `LLMError`, `StorageError`.
  HTTP hataları durum kodu, yanıt gövdesi ve istek parametrelerini içerir.
- Dış API çağrıları: 3 deneme, üstel bekleme, her başarısız denemede uyarı logu, sonra son hata fırlatılır.
- Gizli yedek yok: bulut STT çökerse yerele kendiliğinden geçilmez; ada hatayı gösterir.
- Deepgram bağlantısı koparsa ~120 sn boyunca geri çekilmeli yeniden bağlanır; tükenirse o akış biter ve panelde
  hata görünür. Ses kaydı her durumda diske yazılmaya devam eder.
- Kullanıcıya gösterilen tüm hata metinleri tek saf fonksiyondan (`userFacingMessage`) geçer: Türkçe, ne
  yapılacağını söyler, anahtar ve toplantı metni içermez. Mikrofon ve sistem sesi hataları ayrı adlandırılır;
  ElevenLabs'in kota dolunca döndürdüğü 401 "anahtar geçersiz" değil "kota doldu" olarak gösterilir.
- Başlatılamayan ses akışı için ek "beklenmedik şekilde durdu" gösterilmez.
- ElevenLabs penceresi başarısızsa yalnızca o pencere etkilenir; panelde hata, sonraki pencere denenir.
- Çeviri hatası yalnızca ilgili bölümü etkiler (işaret + "Tekrar dene"); akış devam eder.
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
   konuşmacılara isim verme, dışa aktarma, ses saklama süresi, çökme kurtarma.
6. **Tamamlama:** OpenAI uyumlu LLM, toplantı ortasında dil değişimi, yerel son geçiş (WhisperKit + SpeakerKit),
   karşılama ekranı, ayarlanabilir kısayollar ve süreler, ses çalma, "Bitiriliyor…", saat hizalama, ön-kayıt,
   önceki aşamaların incelemelerinden ertelenen tüm düzeltmeler.

## 9. Riskler ve açık noktalar

- **Deepgram `language=fi` ilk saniyeler:** ikinci ölçümde nedeni bulundu — model kaydın ilk 13 sn'si
  için boş kesin sonuç döndürüyor (kısa, hızlı çocuk konuşması); bağlantı sorunu değil. Aynı kayıtta
  `language=multi` bu kısmı yakaladı; ancak sentetik Fince diyalogda `multi` tamamen bozuk metin üretti
  (`fi` kusursuzdu). Bu yüzden `multi` kullanılmaz.
- **Otomatik modda İngilizce toplantı:** dil algılanana kadar (~15 sn) metin Fince modelle bozuk çıkabilir.
- **Konuşmacı eşleme hataları:** pencereler arası eşleme yanlışsa bir kişi iki numara alabilir;
  toplantı sonrası tüm kayıt üzerinden yapılan ayırma kesin sonucu verir.
- **Maliyet:** iki Deepgram akışı ~0,6–0,9 $/sa + ElevenLabs (örtüşme nedeniyle sesin ~2 katı)
  ~0,45 $/sa → toplam ~1–1,4 $/sa (fiyatlar ikincil kaynaklardan; kendi hesaplarında doğrulanmalı).
- **Ekran paylaşımı görünmezliği** garanti değildir (bkz. 4.1 UI).
- **SpeakerKit (yerel) konuşmacı ayırma:** ölçüm — 12 sn'lik üç sesli sentetik diyalogda herkesi tek kişi saydı
  (eşik 0,3–0,6 fark etmedi), aynı diyalog ~48 sn olunca üç konuşmacıyı doğru ayırdı. Gerçek toplantılar
  dakikalarca sürdüğü için varsayılan ayarlar kullanılır; çok kısa kayıtlarda tek konuşmacı çıkabilir.
- **OpenAI uyumlu sağlayıcılar:** Ollama (`gpt-oss:20b-cloud`) ile gerçek çağrıyla test edildi; yerel 9B düşünen
  model (`bonsai-2:9b`) 120 sn'lik zaman aşımına sığmadı — canlı çeviri için hızlı model seçilmeli.
  OpenCode Go yalnızca OpenAI uyumlu uç noktası üzerinden; gerçek hesapla denenmedi.
