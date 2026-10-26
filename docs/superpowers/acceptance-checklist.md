# Proje sonu kabul testi (elle)

Kullanıcı isteğiyle tüm elle denemeler uygulama bitince birlikte yapılır. Her aşama kendi maddelerini ekler.
Otomatik testler (`swift test`, `AINOTEPAD_CLOUD_TESTS=1`, `AINOTEPAD_MODEL_TESTS=1`) her adımda çalışır.

## Ses yakalama (aşama 1)
- [ ] Mikrofon ve sistem sesi izinleri ilk kayıtta istenir; reddedilince panelde Türkçe hata, diğer akış çalışır
      (`tccutil reset Microphone com.senoldogan.AINotepad`, `tccutil reset AudioCapture com.senoldogan.AINotepad`).
- [ ] Kayıt sırasında AirPods bağla/çıkar: "Sen" ve "Diğerleri" devam eder ya da açık hata görünür.
- [ ] Oturum klasöründe `me.caf` ve `others.caf` oluşur, süreleri kayıtla uyumlu (`afinfo`).
- [ ] 30+ dk kayıt: gecikme büyümez, bellek sabit.

## Bulut STT (aşama 2)
- [ ] Ayarlar: iki anahtar "Kayıtlı"; ilk kayıtta Keychain izni → "Her Zaman İzin Ver".
- [ ] Fince video: kesin metin ~1 sn'de; ~15–20 sn'de "🇫🇮 Fince"; "Diğerleri" → "Konuşmacı N"; numaralar dakikalar boyunca tutarlı.
- [ ] Hoparlörle dinlerken video sesi "Sen" altında tekrar görünmez (yankı filtresi).
- [ ] İngilizce video, dil Otomatik: ilk ~15 sn sonra İngilizce düzgün akar.
- [ ] Wi-Fi 10 sn kapat-aç: metin kendiliğinden devam eder; kopma anındaki cümle kaybolmaz.
- [ ] Yanlış ElevenLabs anahtarı: panelde tek bir "anahtar geçersiz" hatası, metin akmaya devam eder.
- [ ] Kaydı durdur: kırmızı hata yok, kayıt birkaç saniyede biter.
- [ ] Motor "Mac'te (WhisperKit)": model yüklenir, aşama 1 davranışı çalışır.
- [ ] Deepgram ve ElevenLabs panellerinde 10 dk'lık gerçek maliyet; spec §9 tahminiyle karşılaştır.

## Arayüz (aşama 3)
- [ ] Kayıt başlayınca çentikte siyah ada: solda kırmızı nokta + süre, sağda dil; kayıt bitince kaybolur.
- [ ] Fare adanın üstüne gelince yumuşakça açılır, son "Diğerleri" bloğunun metni 2 satırda; çekince kapanır.
- [ ] Adaya tıklama paneli açar/kapatır; kayıt yokken adanın olduğu yer (menü çubuğu ortası, altındaki sekmeler) tıklanabilir kalır.
- [ ] Harici monitörde ya da çentiksiz ekranda ada, menü çubuğunun altında ortada hap olarak görünür; ekran değişince yer değiştirir.
- [ ] Cam panel: arka planından sürüklenir, köşesinden boyutlanır, açık ve koyu duvar kağıdında okunaklı.
- [ ] Panelde konuşmacı renkleri: Sen mavi, Konuşmacı 1 yeşil, 2 turuncu…; kesinleşmemiş metin soluk.
- [ ] ⌃⌥R kayıt başlatır/durdurur, ⌃⌥P ada + paneli gizler/gösterir (uygulama öndeyken de değilken); ⌃⌥Space klavye dilini değiştirmeye devam eder.
- [ ] Adaya sağ tık → "Kaydı durdur"; panel başlığında durdur düğmesi.
- [ ] Menü: ikonlu, kısayollar menüde görünür; Ayarlar penceresi öne gelir.

## Ekran paylaşımı
- [ ] "Ekran görüntülerinde gizle" açık/kapalı: ⌘⇧3/⌘⇧4, ⌘⇧5 kayıt, Zoom tüm ekran paylaşımında panelin görünüp görünmediği (macOS 26'da ekran görüntüsünde göründüğü biliniyor).
