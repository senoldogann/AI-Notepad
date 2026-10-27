# AI-Notepad iPhone — Tasarım Belgesi

Kullanıcı kararları (2026-10-27):
- iPhone uygulaması **iCloud ile eşitlenen tam uygulama**: telefonda kaydeder, canlı metin ve Türkçe çeviri gösterir,
  notu yazar; toplantılar kullanıcının iCloud'u üzerinden Mac'le iki yönlü eşitlenir. Sunucu yok, veriler kullanıcıda.
- Tanıma ve not **bulutta, Mac'teki anahtarlarla**: Deepgram + ElevenLabs + Claude (ya da OpenAI uyumlu). Anahtarlar iCloud
  Anahtar Zinciri ile telefona gelir.

## 1. Amaç

Mac'te olmayan anlarda — yüz yüze toplantı, koridor görüşmesi, ders — telefon cebinden çıkıp kaydetsin; toplantı Mac'e
de gelsin. Telefonda arşive soru sorulabilsin, görevler takip edilebilsin.

## 2. Kısıtlar

- iOS 26+, iPhone. Swift 6, SwiftUI. Kod stili ve kurallar Mac'le aynı (AGENTS.md).
- iOS başka uygulamaların sesini yakalayamaz: telefon yalnızca **mikrofonu** kaydeder (yüz yüze toplantı). Telefondaki
  Teams/Zoom görüşmesi kaydedilmez; bu açıkça söylenir.
- Kayıt ekran kilitliyken ve uygulama arka plandayken sürer (arka plan ses modu); canlı satır Live Activity ile kilit
  ekranında ve Dynamic Island'da görünür.
- Veriler yalnızca cihazda ve kullanıcının iCloud'unda. Anahtarlar Anahtar Zinciri'nde (iCloud Anahtar Zinciri ile
  eşitlenen kopya).

## 3. Mimari

### 3.1 Ortak çekirdek

`Packages/AINotepadCore` hem macOS hem iOS için derlenir:
- `AINotepadCore`: kayıt oturumları (bulut), son geçiş, not, arşiv sorusu, konuşmacı ses izi, webhook, MCP (yalnız macOS).
  macOS'a özgü sistem sesi yakalama `#if os(macOS)` içinde.
- `AINotepadUI`: renkler, yazı tipleri, karaoke, panel bileşenleri; AppKit'e bağlı parçalar platforma göre ayrılır.
- Mikrofon yakalama iOS'ta `AVAudioSession` (`.playAndRecord`, `.measurement`/`.spokenAudio`, Bluetooth) ile kurulur;
  kesintiler (telefon çağrısı) ve rota değişimi (AirPods) ele alınır.

### 3.2 Depolama ve eşitleme (iCloud Drive)

- Toplantı klasörleri (`meeting.json` + `others.m4a`/`me.m4a`) uygulamanın iCloud kapsayıcısında:
  `iCloud.com.senoldogan.AINotepad/Documents/Sessions/<id>/`. Mac ve iPhone aynı klasör yapısını okur ve yazar; biçim
  bugünkü `meeting.json`'dır (yeni alanlar isteğe bağlı kalır).
- Değişiklikler `NSMetadataQuery` ile izlenir; dosyalar `NSFileCoordinator` ile yazılır. Çakışmada (aynı toplantı iki
  cihazda aynı anda değişirse) son yazılan kazanır, diğer sürüm `NSFileVersion` ile kaldırılır ve loglanır.
- Kayıt sürerken ses yerelde (`.caf`) yazılır; toplantı bitip `.m4a`'ya dönüşünce iCloud'a taşınır (yarım dosya
  eşitlenmez).
- Mac'te tek seferlik taşıma: `Application Support/AINotepad/Sessions` → iCloud kapsayıcısı (kullanıcı onayıyla,
  Ayarlar'dan; kopyalayıp doğrular, sonra eskiyi siler). iCloud kapalıysa açık uyarı; uygulama yerel klasörle çalışmayı
  sürdürmez — iCloud ayarı kullanıcının açık seçimidir (Ayarlar › Eşitleme: "iCloud ile eşitle").
- Kişiler (`People.json`), ses izleri (`Voices.json`) ve klasörler de kapsayıcıda.

### 3.3 Anahtarlar

- Mac Ayarlar › Anahtarlar: "iPhone'da da kullan" — anahtarın `kSecAttrSynchronizable` kopyası yazılır (mevcut yerel
  öğe silinmez; testler onu okur).
- iPhone önce eşitlenen kopyayı okur; yoksa telefonda elle girilebilir.
- Paylaşılan erişim grubu (`$(TeamIdentifierPrefix)com.senoldogan.AINotepad`) iki uygulamanın entitlement'ında.

### 3.4 iPhone uygulaması

- **Kayıt** (ana ekran): büyük kayıt düğmesi, dil seçimi, canlı metin (konuşmacılı) ve Türkçe çeviri, "Ne kaçırdım?",
  işaretle, süre ve ses çubukları. Live Activity: süre + son satır; kilit ekranından durdur.
- **Toplantılar:** liste (arama, klasör), toplantı sayfası (özet, görevler, konu akışı, transkript, karaoke çalma,
  paylaş, PDF/web sayfası, webhook).
- **Sor:** akan cevap, kaynaklar.
- **Görevlerim:** açık/tamamlanan, Anımsatıcılar.
- **Ayarlar:** anahtarlar (eşitlenen ya da elle), dil, LLM, eşitleme durumu.
- İşleme (son geçiş + not) kaydı yapan cihazda yapılır; bulut çağrıları arka plan görevleriyle sürer
  (`BGProcessingTask`/`beginBackgroundTask`), yarıda kalırsa uygulama açılınca devam eder.

### 3.5 Tasarım

Mac'teki sade ElevenLabs dili: süt beyazı/koyu zemin, Inter, soluk konuşmacı renkleri, film gradyanlı kapaklar. iOS
gezinme: sekme çubuğu (Kayıt, Toplantılar, Sor, Görevler) + Ayarlar.

## 4. Aşamalar

1. **Temel:** çekirdek iOS'ta derlenir; iOS uygulama hedefi (XcodeGen) simülatörde açılır; ortak depolama katmanı
   (yerel ve iCloud kapsayıcısı) testleriyle.
2. **Kayıt:** iOS mikrofon yakalama (AVAudioSession), bulut canlı oturumu, kayıt ekranı, arka plan kaydı, işleme.
3. **Okuma:** toplantı listesi ve sayfası, çalma, Sor, Görevlerim.
4. **Eşitleme:** iCloud kapsayıcısı (Mac ve iPhone), Mac'te taşıma, anahtar eşitleme, çakışma çözümü.
5. **Cila:** Live Activity / Dynamic Island, widget, Kısayollar ("Toplantıyı kaydet"), TestFlight.

## 5. Riskler

- iCloud kapsayıcısı ve paylaşılan Anahtar Zinciri grubu Apple Developer hesabında yetki (capability) ister; Mac'in
  Developer ID dağıtımı için iCloud'lu provisioning profile gerekir (release.sh güncellenir).
- iCloud Drive eşitleme gecikmesi (saniyeler–dakikalar); arayüz "eşitleniyor" durumunu gösterir.
- Telefonda uzun kayıt pili: bulut akışı düşük güçte; WhisperKit telefonda yok (kullanıcı kararı).
