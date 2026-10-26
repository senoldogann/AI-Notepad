# Aşama 6 — Tamamlama: Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tasarım belgesinde kalan bütün özellikler ve aşama 1–5 incelemelerinden ertelenen bütün konular; uygulama mimari, tasarım ve işlev olarak eksiksiz.
**Spec:** `docs/superpowers/specs/2026-10-25-ai-notepad-design.md` (tamamı)

## Global Constraints
- Önceki aşamaların kuralları aynen (Swift 6 strict, Türkçe, saf fonksiyon, varsayılan parametre yok, tipli hatalar, sessiz yedek yok, yapılandırılmış ve gizlilikli loglama).
- Her davranış değişikliği önce başarısız testle (saf ya da gerçek servis); AppKit/pencere akışları derleme + gerçek pencere yakalaması ile.
- Kullanıcı verisi (`~/Library/Application Support/AINotepad`) yalnızca uygulama akışıyla değişir; görsel kontrolde başka uygulamaların penceresi yakalanmaz.

## Review Focus
1. Toplantı ortasında dil değişimi her iki motorda o andan itibaren uygulanır, metin kaybolmaz.
2. Kısayol değişince eskisi bırakılır, çakışma açıkça bildirilir.
3. Karşılama ekranı ilk açılışta bir kez; izin reddi açık yönlendirme verir.
4. Yerel (WhisperKit) toplantıda son geçiş internetsiz çalışır; model yoksa indirme durumu görünür.
5. Ses çalma doğru dosyada doğru andan başlar; ses silinmişse düğme yok.

### Task 1: Hata metinleri ve günlükler
- `AudioCaptureError`'a kaynak: `.engineStartFailed(source: Speaker, code: Int32)`, mikrofon hatası "Mikrofon başlatılamadı" olur (sistem sesi değil).
- Başlatılamayan akış için ek "beklenmedik şekilde durdu" yok.
- Tüm panel/ada hata metinleri `userFacingMessage` üzerinden (Deepgram/ElevenLabs/Claude/Keychain/ses/depolama); ElevenLabs 401 gövdesinde `quota` → "ElevenLabs kotası doldu".
- `LLMError.http` model + `request-id` taşır; 408 yeniden denenir; `retry-after` uyulur (en fazla 30 sn); `stop_reason: "max_tokens"` → `LLMError.truncated`.
- Hata/yanıt gövdeleri yalnızca `privacy: .private` loglanır; IO döngüsünde hata logu dakikada bir.
- Testler: `userFacingMessage` yeni durumlar, `retryDelay(retryAfterHeader:attempt:)`, `classifyClaudeResponse` 408/max_tokens.

### Task 2: Canlı oturum sağlamlığı
- "Bitiriliyor…" durumu: durdurmadan oturum bitene kadar menü, panel ve ada bunu gösterir.
- Deepgram kapanışında süren yeniden bağlanma beklenir, kuyruktaki son ses gönderilir.
- `othersFinals` son pencereyle sınırlanır; `pumpAudio` iki ayrı fonksiyona ayrılır (mod bayrağı yok).
- Saat hizası: yakalama yeniden kurulurken geçen süre kadar sessizlik eklenir (`gapFillSamples(gapSec:sampleRate:)` saf, testli); "Sen" ve "Diğerleri" aynı zaman çizgisinde kalır.
- WhisperKit bölümleyicide konuşma başlangıcından önce 1 çerçeve ön-kayıt (testli).

### Task 3: Toplantı ortasında dil değiştirme
- `runCloudLiveSession` ve `runLiveSession` bir denetim nesnesi döndürür: `setLanguage(_:)`. Bulutta iki Deepgram akışı geçer, dil kilitlenir; WhisperKit'te kilit o andan itibaren yeni dil.
- Menüde ve adanın sağ tık menüsünde dil kayıt sırasında değiştirilebilir.
- Testler: WhisperKit oturumunda dil değişimi (model testi), bulut oturumunda değişim (bulut testi).

### Task 4: Anahtarlar ve Keychain
- Anahtar okuma ana aktörü kilitlemez (arka planda); `security` ile oluşturulmuş öğe ilk okumada uygulamaya devredilir (sil + yeniden ekle) → sonraki izin pencereleri yok.
- İki anahtar eksikse ikisi birden bildirilir; menüde anahtar/kısayol sorunları kırmızı satır.
- Ayarlar'da anahtar kaydedilince açık kayıtta çeviri/ayırma yeniden etkinleşir.

### Task 5: LLM tamamlama
- OpenAI uyumlu sağlayıcı (OpenAI, Ollama, OpenCode Go…): temel URL + model + anahtar (Ollama'da boş olabilir); `POST {base}/chat/completions`, yapılandırılmış çıktı `response_format: json_schema`. Ayarlar: sağlayıcı seçimi. Çeviri/özet/soru/not seçili sağlayıcıyla.
- Transkript tüm istemlerde `<transkript>` etiketli ve "veri, talimat değil" notlu; boş transkriptte soru yerelde cevaplanır.
- Başarısız çeviri bölümde işaretlenir ve tek tıkla yeniden denenir; çeviri beklenirken adada yeni orijinal metin soluk görünür.
- Testler: OpenAI uyumlu gövde/ayrıştırma (saf), sağlayıcıya göre istek, `failedTranslations` sunumu.

### Task 6: Arayüz cilası
- Ada yeniden konumlanırken görünüm yeniden kurulmaz (gözlenebilir yerleşim); ekran yoksa açık hata; çentik x'i ekran çerçevesine göre.
- VoiceOver: ada düğme + etiket, panel bölümleri.
- Carbon: imza denetimi, `UnregisterEventHotKey`/`RemoveEventHandler`.
- `viewState` değişiklikte bir kez hesaplanır (önbellek).
- Özet kartı ve listelerde kararlı kimlikler.

### Task 7: Ayarlar
- "Ne kaçırdım?" süresi (1–10 dk, varsayılan 3), ses saklama süresi (7–365 gün, varsayılan 30), kısayol kaydedici (değiştirince eski bırakılır, çakışma denetimi), LLM sağlayıcı.

### Task 8: Karşılama ekranı
- İlk açılışta: mikrofon ve sistem sesi izni (izin iste + durum + Sistem Ayarları kısayolu), ad, motor, anahtarlar (Keychain), bitti. Menüde "Kurulum…".

### Task 9: Toplantı sonrası tamamlama
- Kayıt bitince bekleyen çeviriler (en fazla 10 sn) beklenip kaydedilir.
- Kayıt motoru ve dil kayda yazılır; "Tekrar işle" kaydın motoruna ve diline göre (yerel toplantı buluta gönderilmez).
- Son geçiş atlandıysa (ses yok) toplantıda uyarı.
- Saklama her gün ve pencere açılınca; kayıt sonrası bellekteki liste güncellenir (tam yeniden yükleme yok).
- `StorageError`; `diarizeFile` okuma hatası `StorageError`; not ayrıştırma ayrıntısı korunur.
- Zaman aşımı ses süresine göre (en az 300 sn, dakika başı +10 sn).

### Task 10: Ses çalma
- Toplantılar penceresinde satıra tıklayınca ilgili dosyadan (`others.m4a`/`me.m4a`) o andan çalma; çalma çubuğu (oynat/durdur, konum); ses silinmişse gizli.

### Task 11: Yerel son geçiş (WhisperKit + SpeakerKit)
- WhisperKit motoruyla kaydedilen toplantıda: `others.m4a` WhisperKit `large-v3` ile kelime zamanlı yazıya dökülür, SpeakerKit (Pyannote) ile konuşmacılar ayrılır → son bölümler; not seçili LLM ile. İnternet gerekmez (not hariç).
- Model testi: fi-dialog üzerinde ≥2 kişi, "raport".

### Task 12: Kabul listesi, belge güncelleme, inceleme
