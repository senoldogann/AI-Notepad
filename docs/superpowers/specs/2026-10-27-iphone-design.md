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

- Kayıt ve işleme her cihazda yerel `Sessions` klasöründe yapılır (yarım ses dosyası eşitlenmez). iCloud açıksa biten
  (`done`) toplantının klasörü `iCloud.com.senoldogan.AINotepad/Documents/Sessions/<id>/`'e taşınır (`setUbiquitous`);
  biçim bugünkü `meeting.json` + `others.m4a`/`me.m4a`.
- Liste yerel ve iCloud klasörünün birleşimidir; aynı toplantı ikisinde varsa yereldeki kullanılır. Değişiklikler
  `NSMetadataQuery` ile izlenir; inmemiş dosyanın indirmesi başlatılır, okuma beklemez. `meeting.json` dosya
  koordinatörüyle yazılır; çakışmada son yazılan kalır, diğer sürümler kaldırılır ve loglanır.
- Ayar (`storage.location`) iki uygulamada da açık seçimdir (varsayılan yerel). Açınca bitmiş toplantılar taşınır,
  kapatınca iCloud'dakiler o cihaza geri taşınır. iCloud kullanılamıyorsa neden ayarlarda ve listede görünür; yerel
  toplantılar listelenmeye devam eder.
- Kişiler (`People.json`), ses izleri (`Voices.json`) ve klasörler şimdilik Mac'te yerel kalır (iPhone kullanmıyor).

### 3.3 Anahtarlar

- Mac Ayarlar › Anahtarlar › "iPhone'a gönder": kayıtlı anahtarların iCloud Anahtar Zinciri ile eşitlenen kopyası
  (`kSecAttrSynchronizable`, veri koruma anahtar zinciri) yazılır; yerel öğeye dokunulmaz. Mac ve iPhone uygulamasının
  kimliği aynı (`TAKIM.com.senoldogan.AINotepad`) olduğu için varsayılan erişim grubu ortaktır.
- iPhone önce cihazda girilen anahtarı, yoksa Mac'ten geleni okur.

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
