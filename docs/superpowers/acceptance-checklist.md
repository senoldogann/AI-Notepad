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

## Türkçe çeviri ve asistan (aşama 4)
- [ ] Ayarlar'da Anthropic anahtarı "Kayıtlı"; ilk kullanımda Keychain izni → "Her Zaman İzin Ver".
- [ ] Fince video: her "Diğerleri" cümlesinin altında 1–2 sn içinde doğal Türkçesi; "Sen" cümleleri çevrilmez.
- [ ] Görünüm "Sadece Türkçe": orijinal metin gizlenir, çevirisi gelmemiş metin soluk orijinal kalır.
- [ ] Ada açılınca son cümlenin Türkçesi görünür.
- [ ] "Ne kaçırdım?": birkaç saniyede konu / kararlar / senden istenenler kartı; kapat düğmesi çalışır.
- [ ] Soru alanına Türkçe soru yazılabiliyor (panel klavye alıyor); cevap zaman damgalı.
- [ ] Yanlış Anthropic anahtarı: tek bir "anahtar geçersiz" hatası, canlı metin akmaya devam eder.
- [ ] Anthropic panelinde 10 dk'lık çeviri maliyeti (Haiku: birkaç sent bekleniyor).

## Toplantı sonrası (aşama 5)
- [ ] Ayarlar'da "Adın" gir; kayıt bitince menüde "Toplantı işleniyor…", ~1 dk içinde biter.
- [ ] Menü → Toplantılar: toplantı başlıkla listede; not (özet, kararlar, görevler — senin görevlerin mavi yıldızlı, sözlük).
- [ ] Transkript son geçişle (ElevenLabs) ve "Konuşmacı N" etiketleriyle; "Konuşmacı 1" → "Aino" yazıp Enter: transkript ve Markdown'da Aino.
- [ ] Arama: Fince bir kelime ve Türkçe nottaki bir kelime ile bulunuyor.
- [ ] Markdown kopyala → Notes'a yapıştır; Markdown kaydet → .md dosyası.
- [ ] Anthropic anahtarı yokken kayıt: toplantı "Hata" (not yok) ama transkript var; anahtarı ekle → "Tekrar işle" → not oluşur.
- [ ] Kayıt sırasında uygulamayı zorla kapat (Etkinlik Monitörü) → yeniden aç: toplantı "Yarıda kaldı"; "Tekrar işle" çalışır.
- [ ] "Sesi sil": m4a dosyaları gider, metin/not kalır. 30 günden eski toplantının sesi açılışta silinir.

## Tamamlama (aşama 6)
- [ ] İlk açılışta panelde Kurulum sayfası: mikrofon "İzin ver" → izin penceresi; "İzin penceresini aç" → sistem sesi izni; ad, motor, anahtarlar; "Başla" sonrası bir daha açılmaz; menüde "Kurulum" ile yeniden açılır.
- [ ] Anahtarı eksik motor seçiliyken menüde kırmızı satır; Ayarlar'dan ekleyince kaybolur. Deepgram ve ElevenLabs ikisi de eksikken kayıt: iki hata birlikte.
- [ ] Kayıt sırasında menü → "Dili değiştir" → İngilizce (ya da panelin dil çipi, adanın sağ tık menüsü): sonraki cümleler İngilizce, dil çipi "🇬🇧 İngilizce".
- [ ] Kaydı durdurunca ada, panel ve menü "Bitiriliyor…" gösterir; bu sırada yeni kayıt başlatılamaz; bitince toplantı işlenir.
- [ ] Panel › Ayarlar › Kısayollar: kayıt kısayolunu ⌃⌥K yap → ⌃⌥K çalışır, ⌃⌥R artık çalışmaz; ⌃⌥Space ya da yalnızca "K" reddedilir ve eski kısayol çalışır; menüdeki ipucu güncellenir.
- [ ] Ayarlar › Genel: "Ne kaçırdım?" 5 dk → kart son 5 dakikayı özetler; ses saklama 7 gün → 7 günden eski toplantıların sesi silinir.
- [ ] Ayarlar › LLM: OpenAI uyumlu + Ollama (`http://localhost:11434/v1`, hızlı bir model) → "Bağlantıyı dene" Türkçe cevap; kayıtta çeviri, "Ne kaçırdım?" ve not Ollama ile.
- [ ] Kayıt sırasında Anthropic anahtarını kaldır → çeviri hatası, bloğun altında "Çeviri alınamadı · Tekrar dene"; anahtarı geri ekle → "Tekrar dene" çevirir.
- [ ] Toplantılar: zaman damgasına tıklayınca o andan ses çalar, çalan satır mavi çizgiyle vurgulu, alttaki çubukta duraklat/konum; "Sesi sil" sonrası çalma düğmeleri yok.
- [ ] Motor "Mac'te" ile 2+ dk'lık çok konuşmacılı video: Wi-Fi kapalıyken kayıt; toplantı sonrası "Konuşmacı 1/2…" (SpeakerKit), not için LLM gerekir.
- [ ] Bulut motorunda ElevenLabs anahtarını kaldırıp kayıt: toplantıda "Son geçiş yapılmadı: ElevenLabs anahtarı kayıtlı değil." uyarısı.
- [ ] VoiceOver (⌘F5): ada "AI-Notepad, Kayıtta, 🇫🇮 Fince, …" okunur; panel düğmeleri adlarıyla okunur.
- [ ] Kayıt sırasında AirPods bağla: "Sen" ve "Diğerleri" zaman damgaları kaymaz (toplantı sonrası transkriptte sıralama doğru).

## Geri bildirim sonrası (aşama 6b)
- [ ] Hoparlörle Fince video, sen konuşmuyorsun: "Sen" satırı çıkmıyor (canlıda ve Toplantılar'da); kendi konuşman görünüyor.
- [ ] Panelde mikrofon düğmesi (ya da Ayarlar › Genel › Mikrofon) kapalıyken "Sen" hiç yazılmıyor; tercih yeniden açılışta korunuyor.
- [ ] Toplantı sayfasında transkript paragraflı: aynı konuşmacının cümleleri tek paragraf, satır satır bölünmüyor.
- [ ] Görünüm "Sadece orijinal": Türkçe yok, ada orijinali gösteriyor; toplantı sonunda Türkçe not yine hazır.
- [ ] Panelden Başlat → Duraklat ("Duraklatıldı", metin durur) → Devam → Bitir; menüden de Duraklat/Devam.
- [ ] Bitir'e basınca panel "Bitiriliyor…", ardından kendiliğinden toplantı sayfasına geçiyor; en üstte "Senin görevlerin".
- [ ] PDF düğmesi: İndirilenler'de temiz PDF (görevler, özet, kararlar, sözlük, transkript; sayfa numaraları); "Finder'da göster" çalışıyor; PDF'ten kopyalanan metin doğru.
- [ ] Ayarlar, Toplantılar ve Kurulum ayrı pencere açmıyor; hepsi panelin içinde, geri düğmesiyle dönülüyor; kayıt sürerken "Kayıtta" ile canlıya dönülüyor.
- [ ] Panel ayarlarda yazı alırken (anahtar, ad, model) başka uygulama önde kalıyor ama yazılabiliyor; anahtar ⌘V ile ya da "Yapıştır" düğmesiyle yapıştırılabiliyor.
- [ ] İlk PDF/Markdown dışa aktarmada macOS'un tek seferlik "İndirilenler klasörüne erişim" izni çıkabilir (sistem penceresi; uygulamanın değil).
- [ ] Toplantıda soruya soruyu tekrar ederek cevap ver ("Joo, teen diat perjantaiksi"): cevabın "Sen" olarak canlıda ve notta duruyor.
- [ ] Bir toplantı bittikten sonra yeni kayıt (kısayol ya da menü): panel canlı sayfada açılıyor; panel gizliyken toplantı bitince panel toplantı sayfasıyla görünüyor.

## Arayüz dili, görünüm ve modeller (aşama 6c)
- [ ] Ayarlar › Genel › Arayüz dili: English → "Şimdi yeniden başlat": menü, panel, Ayarlar, Toplantılar, Kurulum, hata mesajları, PDF/Markdown başlıkları İngilizce; tarihler İngilizce; not içeriği ve çeviri Türkçe kalıyor. Türkçe/Sistem'e dönüş çalışıyor.
- [ ] Mikrofon/sistem sesi izin pencerelerindeki açıklama arayüz diline göre.
- [ ] Ayarlar › LLM: çeviri modeli Sonnet 5.5 / effort Yüksek, not modeli Fable 5.1 / Orta seç → "Bağlantıyı dene" ve kayıtta çeviri ile not çalışıyor.
- [ ] Ayarlar › Görünüm: tema Koyu/Açık, vurgu rengi, arka plan "Koyu cam"/"Opak", yazı tipi, metin boyutu, satır aralığı, alt boşluk panelde anında değişiyor; "Varsayılana döndür" çalışıyor; ada kapatılınca kayıtta çentikte görünmüyor.
- [ ] Panel köşeleri dört köşede de yuvarlak; kenar ve gölge dikdörtgen değil.
- [ ] Konuşma akarken transkript kendiliğinden en alta iniyor ve altta boşluk var; yukarı kaydırınca yerinde kalıyor, "Yeni metin" düğmesi çıkıyor.
- [ ] Panel başlığındaki ve sayfalardaki düğmelerin üzerine gelince açıklama çıkıyor (uygulama arka plandayken de).

## Ada, toplantı sayfası, oynatıcı, konuşmacı düzeltme (aşama 6d)
- [ ] Ada açılınca: konuşmacı adı, son cümlenin Türkçesi büyük, altında konuşulan orijinal küçük; "…" ile parçalanmış metin yok.
- [ ] Kayıtta bir "Konuşmacı 2" bloğunun etiketine tıkla → "Konuşmacı 1"e ata: blok anında Konuşmacı 1; sonraki ayırma pencereleri bunu bozmuyor. "Tümünü birleştir" geçmiş ve yeni bölümleri birleştiriyor.
- [ ] Toplantı sayfasında Özet / Transkript sekmeleri; not varsa Özet'te açılıyor.
- [ ] "Dinle": iki taraf birlikte duyuluyor; alttaki kartta konuşmacı, konum, ±10 sn, hız çalışıyor; transkriptte söylenen kelime renkleniyor ve çalan paragraf ortaya kayıyor; paragrafa tıklayınca oradan çalıyor.
- [ ] Toplantı sayfasında konuşmacı satırındaki birleştir simgesiyle iki konuşmacı birleşiyor; ad taşınıyor.

## Hazırlanma kartı
- [ ] Bitir'e bas: panel bulanıklaşıyor, ortada animasyonlu kart; adımlar sırayla ✓ oluyor; bitince kart kayboluyor ve toplantı sayfası (görevler üstte) açık.
- [ ] "Arka planda devam et": kart kapanıyor, panel kullanılabiliyor; aynı kayıt için tekrar açılmıyor; sonraki kayıtta yine çıkıyor.

## Duyarlı düzen
- [ ] Paneli en küçük boyuta (köşeden) küçült: canlı sayfada başlık taşmıyor (düğmeler "⋯" menüsünde), "Ne kaçırdım?" simge; Toplantılar, toplantı sayfası (düğmeler alt satıra akıyor), Ayarlar (sekmeler açılır seçici), Kurulum taşmadan kullanılabiliyor.
- [ ] Harici monitörde paneli sağ alta koyup monitörü çıkar: panel dizüstü ekranının içine geliyor ve sığıyor.

## Ekran paylaşımı
- [ ] "Ekran görüntülerinde gizle" açık/kapalı: ⌘⇧3/⌘⇧4, ⌘⇧5 kayıt, Zoom tüm ekran paylaşımında panelin görünüp görünmediği (macOS 26'da ekran görüntüsünde göründüğü biliniyor).
