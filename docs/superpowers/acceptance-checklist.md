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
- [ ] Kayıttan önce paneldeki mikrofon düğmesi (ya da Ayarlar › Genel › "Kendi sesimi de kaydet") kapalıyken kayıt başlayınca menü çubuğunda mikrofon göstergesi yanmıyor, "Sen" hiç yazılmıyor, karşı taraf yazılıyor; kayıtta mikrofon düğmesi kapalı. Tercih yeniden açılışta korunuyor.
- [ ] Toplantı sayfasında düğmelerin üstüne gelince tek ipucu görünüyor, alttaki satırla üst üste binmiyor ve birkaç saniyede kayboluyor.
- [ ] Toplantı sayfasında transkript paragraflı: aynı konuşmacının cümleleri tek paragraf, satır satır bölünmüyor.
- [ ] Ayarlar › Genel › "Kayıt sırasında Türkçeye çevir" kapalı (varsayılan): Türkçe yok, ada orijinali gösteriyor; toplantı sonunda Türkçe not yine hazır. Açınca "İki dil / Sadece Türkçe" seçilebiliyor ve sonraki cümleler çevriliyor.
- [ ] Uzun toplantı (≥ 1 saat): not parça parça yazılıyor; her konudaki görevler ayrı maddeler olarak notta, sonradan ertelenen görevin son tarihi doğru.
- [ ] Panelden Başlat → Duraklat ("Duraklatıldı", metin durur) → Devam → Bitir; menüden de Duraklat/Devam.
- [ ] Bitir'e basınca panel "Bitiriliyor…", ardından kendiliğinden toplantı sayfasına geçiyor; en üstte "Senin görevlerin".
- [ ] PDF düğmesi: İndirilenler'de temiz PDF (görevler, özet, kararlar, sözlük, transkript; sayfa numaraları); "Finder'da göster" çalışıyor; PDF'ten kopyalanan metin doğru.
- [ ] Panel ayarlarda yazı alırken (anahtar, ad, model) başka uygulama önde kalıyor ama yazılabiliyor; anahtar ⌘V ile ya da "Yapıştır" düğmesiyle yapıştırılabiliyor.
- [ ] İlk PDF/Markdown dışa aktarmada macOS'un tek seferlik "İndirilenler klasörüne erişim" izni çıkabilir (sistem penceresi; uygulamanın değil).
- [ ] Toplantıda soruya soruyu tekrar ederek cevap ver ("Joo, teen diat perjantaiksi"): cevabın "Sen" olarak canlıda ve notta duruyor.
- [ ] Bir toplantı bittikten sonra yeni kayıt (kısayol ya da menü): panel canlı sayfada açılıyor; panel gizliyken toplantı bitince panel toplantı sayfasıyla görünüyor.

## Arayüz dili, görünüm ve modeller (aşama 6c)
- [ ] Ayarlar › Genel › Arayüz dili: English → "Şimdi yeniden başlat": menü, panel, Ayarlar, Toplantılar, Kurulum, hata mesajları, PDF/Markdown başlıkları İngilizce; tarihler İngilizce; not içeriği ve çeviri Türkçe kalıyor. Türkçe/Sistem'e dönüş çalışıyor.
- [ ] Mikrofon/sistem sesi izin pencerelerindeki açıklama arayüz diline göre.
- [ ] Ayarlar › LLM: çeviri modeli Sonnet 5.5 / effort Yüksek, not modeli Fable 5.1 / Orta seç → "Bağlantıyı dene" ve kayıtta çeviri ile not çalışıyor.
- [ ] Ayarlar › Görünüm: tema Koyu/Açık, vurgu rengi, yazı tipi, metin boyutu, satır aralığı, alt boşluk panelde anında değişiyor; "Varsayılana döndür" çalışıyor; ada kapatılınca kayıtta çentikte görünmüyor.
- [ ] Panel köşeleri dört köşede de yuvarlak; kenar ve gölge dikdörtgen değil.
- [ ] Konuşma akarken transkript kendiliğinden en alta iniyor ve altta boşluk var; yukarı kaydırınca yerinde kalıyor, "Yeni metin" düğmesi çıkıyor.
- [ ] Panel başlığındaki ve sayfalardaki düğmelerin üzerine gelince açıklama çıkıyor (uygulama arka plandayken de).

## Ada, toplantı sayfası, oynatıcı, konuşmacı düzeltme (aşama 6d)
- [ ] Ada açılınca: konuşmacı adı, son cümlenin Türkçesi büyük, altında konuşulan orijinal küçük; "…" ile parçalanmış metin yok.
- [ ] Kayıtta bir "Konuşmacı 2" bloğunun etiketine tıkla → "Konuşmacı 1"e ata: blok anında Konuşmacı 1; sonraki ayırma pencereleri bunu bozmuyor. "Tümünü birleştir" geçmiş ve yeni bölümleri birleştiriyor.
- [ ] Toplantı sayfasında Özet / Transkript sekmeleri; not varsa Özet'te açılıyor.
- [ ] "Dinle": iki taraf birlikte duyuluyor; alttaki kartta konuşmacı, konum, ±10 sn, hız çalışıyor; transkriptte söylenen kelime renkleniyor ve çalan paragraf ortaya kayıyor; paragrafa tıklayınca oradan çalıyor.
- [ ] Toplantı sayfasında konuşmacı satırındaki birleştir simgesiyle iki konuşmacı birleşiyor; ad taşınıyor.
- [ ] Transkript › "Gözden geçir": kartta ad/birleştirme önerileri nedenleriyle görünüyor; ✓ adı veriyor ya da birleştiriyor, ✕ öneriyi kaldırıyor; "Kontrol et" anına tıklayınca oradan çalıyor; uygulayınca "Notu yenile" notu yeni adlarla yazıyor.

## Hazırlanma kartı
- [ ] Bitir'e bas: panel bulanıklaşıyor, ortada animasyonlu kart; adımlar sırayla ✓ oluyor; bitince kart kayboluyor ve toplantı sayfası (görevler üstte) açık.
- [ ] "Arka planda devam et": kart kapanıyor, panel kullanılabiliyor; aynı kayıt için tekrar açılmıyor; sonraki kayıtta yine çıkıyor.

## Duyarlı düzen
- [ ] Paneli en küçük boyuta (köşeden) küçült: canlı sayfada başlık taşmıyor (düğmeler "⋯" menüsünde), "Ne kaçırdım?" simge; Toplantılar, toplantı sayfası (düğmeler alt satıra akıyor), Ayarlar (sekmeler açılır seçici), Kurulum taşmadan kullanılabiliyor.
- [ ] Harici monitörde paneli sağ alta koyup monitörü çıkar: panel dizüstü ekranının içine geliyor ve sığıyor.

## Ekran paylaşımı
- [ ] "Ekran görüntülerinde gizle" açık/kapalı: ⌘⇧3/⌘⇧4, ⌘⇧5 kayıt, Zoom tüm ekran paylaşımında panelin görünüp görünmediği (macOS 26'da ekran görüntüsünde göründüğü biliniyor).

## Ana pencere: kayıt ekranı ve arama
- [ ] Kayıt başlayınca ana pencerenin içeriği bulanıklaşıyor (koyu perde yok); ortada büyük ses ölçer, süre, Duraklat/Devam, "Paneli göster" ve kırmızı "Bitir". Açık ve koyu temada yazılar okunuyor.
- [ ] "Uygulamaya dön" ya da Esc ekranı kapatıyor; üst çubuktaki "Kayıtta" hapı geri açıyor. Ekran açıkken yazılan tuşlar ve Return arkadaki alanlara (Sor kutusu) gitmiyor.
- [ ] Kayıt ekranı açık ve boştayken Etkinlik Monitörü'nde CPU düşük (ana sayfadaki kayıt simgesi bulanıklığın altında titremiyor).
- [ ] ⌘K ve ⌘F arama penceresini açıyor: arkası buzlu cam gibi açık bulanıklaşıyor; ↑↓ seçiyor, Return toplantıyı açıyor, "Tüm sonuçları listede göster" aramayı listeye uyguluyor; Esc ya da dışarı tıklama kapatıyor.
- [ ] En dar pencerede üst çubuk taşmıyor: başlık tek satır, arama hapı daralıyor.

## Kurulum
- [ ] İlk açılışta kurulum: soldaki film gradyanlı panelde yazılar koyu ve okunuyor; sağda içerik üstte, düğmelerin üstünde adımların yol haritası (biten adım onaylı, şimdiki vurgulu). Biten adıma tıklayınca o adıma dönülüyor.
- [ ] İngilizce arayüz ve %115 boyutta, en küçük pencerede yol haritası kesilmiyor (yer darsa önce açıklamalar gizleniyor).

## iPhone uygulaması
- [ ] İlk açılış: kurulum, mikrofon izni; Kayıt sekmesinden yüz yüze toplantı kaydı, canlı metin ve (açıksa) Türkçe çeviri.
- [ ] Kilit ekranında ve Dynamic Island'da Live Activity; Kısayollar ve Denetim Merkezi düğmesiyle kayıt başlatılıp bitiriliyor.
- [ ] Kayıt bitince not hazırlanıyor; Toplantılar, Görevlerim ve Sor sekmeleri çalışıyor; toplantı çalınıyor.
- [ ] Inter yazı tipi her ekranda; İngilizce arayüzde metinler kesilmiyor.

## iCloud eşitleme (iki cihaz)
- [ ] Mac'te Ayarlar'dan iCloud eşitlemesini aç: biten toplantılar iCloud Drive'a taşınıyor, iPhone'da görünüyor.
- [ ] iPhone'da kaydedilen toplantı Mac'te görünüyor; birinde ad, görev ya da not düzenlemesi ötekine geçiyor.
- [ ] Anahtarlar iCloud Anahtar Zinciri ile iPhone'a gönderilince iPhone anahtar sormadan not hazırlıyor.
- [ ] Bir cihazda silinen toplantı ötekinden de kalkıyor; kayıt ya da işleme sürerken eşitleme toplantıyı bozmuyor.
- [ ] Eşitleme kapalıyken toplantılar yalnızca `~/Library/Application Support/AINotepad` altında.

## Kanallar (birden çok hedef)
- [ ] Ayarlar › Bağlantılar: Slack, Teams, Discord, Zoom, Notion, webhook, Apple Notlar ve klasör kartlarında marka logoları; açık ve koyu temada okunuyor.
- [ ] İngilizce arayüz ve %115 boyutta kartlar kesilmiyor (dar alanda tek sütun); "N bağlı" rozeti başlığın altında.
- [ ] Aynı anda iki hedef (ör. Slack ve Discord) bağlı: her birinin kendiliğinden gönderimi ayrı açılıp kapanıyor; toplantı bitince ikisine de gidiyor.
- [ ] "Deneme mesajı gönder": gönderilirken kâğıt uçak sakince atıyor; "gönderildi" birkaç saniyede, hata biraz daha sonra kendiliğinden kayboluyor.
- [ ] Toplantı sayfası › ⋯ › Kanala gönder: "Kanala gönderiliyor…" sonra "Not kanala gönderildi"; sonuç satırı birkaç saniyede kayboluyor.
- [ ] Oturumu düşen hedefte "yeniden bağlan" uyarısı kalıyor; "Yeniden bağlan" ile düzeliyor.

## Notion, Linear ve Jira (MCP)
- [ ] Notion: tarayıcıda izin verince bağlanıyor; not seçilen özel sayfaya yeni sayfa olarak gidiyor; "Vazgeç" girişi iptal ediyor.
- [ ] Linear ve Jira: Ayarlar › Bağlantılar › Görev araçları'ndan bağlan; toplantı sayfası › ⋯ › Görevleri gönder işleri açıyor, özet satırında açılan işler.
- [ ] Kısmi başarısızlıkta yeniden gönderince yalnızca kalan görevler gidiyor.

## Yerel MCP sunucusu ve Skill
- [ ] Ayarlar › Bağlantılar: Claude Desktop, Cursor ve VS Code kartlarından "Bağla" yapılandırmaya AI-Notepad'i ekliyor (diğer ayarlar korunuyor); "Kaldır" çıkarıyor.
- [ ] Claude Desktop'ta toplantılar listeleniyor, aranıyor ve okunuyor (salt okunur); uygulama kapalıyken de çalışıyor.
- [ ] `skills/ai-notepad-meetings` Claude'a yüklenince haftalık özet ve takip e-postası istekleri MCP üzerinden çalışıyor.
- [ ] Başka araç için yazılmış bir Skill içe aktarılıyor ve Sor'da `/` ile çalışıyor.

## Dağıtım: DMG ve Gatekeeper
- [ ] `scripts/release.sh` `AI-Notepad-0.1.3.dmg` üretiyor (adda tek sürüm), noter onayı ekli.
- [ ] Temiz bir kullanıcı hesabında DMG'yi aç, uygulamayı Uygulamalar'a sürükle, aç: Gatekeeper uyarısız açıyor (`spctl --assess` geçiyor).
- [ ] Uygulamanın içinde lisanslar var: `Contents/Resources/NOTICE`, `WhisperKit-LICENSE.txt`, `WhisperKit-NOTICES.txt`, `Inter-OFL.txt`.
- [ ] Güncelleme kurulumunda izinler (mikrofon, sistem sesi) korunuyor; `scripts/install-app.sh` kayıt ya da işleme sürerken kurmayı reddediyor.
