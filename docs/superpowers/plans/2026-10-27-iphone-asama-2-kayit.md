# iPhone aşama 2 — Kayıt

Tasarım: `docs/superpowers/specs/2026-10-27-iphone-design.md`.

## Hedef

Telefon yüz yüze toplantıyı kaydeder: canlı metin (konuşmacılı) ve Türkçe çeviri akar; "Bitir"den sonra toplantı Mac'teki
`processMeeting` ile işlenir (ses, ElevenLabs son geçişi, Claude notu) ve Toplantılar'da görünür.

## Adımlar

1. `MicrophoneCapture` iOS'ta ses oturumu açar (`.playAndRecord`, hoparlöre varsayılan, Bluetooth yalnız A2DP), kayıt
   bitince bırakır; telefon çağrısı gibi kesinti bitince motor Mac'teki yeniden kurma yoluyla yeniden başlar.
2. `PhoneRecorder` (iOS): Deepgram + ElevenLabs anahtarı yoksa başlamaz (eksiklerin hepsi bildirilir); mikrofon "Diğerleri"
   akışına gider (yüz yüze), `runCloudLiveSession`; çeviri en fazla 4 paralel, Türkçe toplantıda çeviri yok; 30 sn'de bir
   transkript saklanır. Anahtarlar kayıt başında okunur (ekran kilitliyken Anahtar Zinciri okunamaz).
3. İşleme: `beginBackgroundTask` ile arka planda sürer; uygulama kapanırsa açılışta kayıtta/işlemede kalan toplantılar
   yeniden işlenir.
4. Kayıt ekranı: dil menüsü, büyük kayıt düğmesi; kayıtta süre, dil, ses çubukları, konuşmacılı canlı metin + Türkçe, "Bitir";
   bitince hazırlanma adımları kartı.
5. Ayarlar: Deepgram, ElevenLabs, Anthropic anahtarları (bu iPhone'un Anahtar Zinciri), ana toplantı dili, ad.
6. Doğrulama: Mac ve iOS simülatörü testleri, Mac ve iPhone derlemesi; kayıt ekranı (`--ornek-kayit`, yalnız Debug) ve
   Ayarlar ekran görüntüsüyle.

## Durum

- [x] 1–6. Gerçek mikrofonla bulut kaydı telefonda elle kabul testinde denenecek (simülatöre anahtar girilmedi).
- Sonraya: canlı kaydı kilit ekranında gösteren Live Activity ve uzun işleme için `BGContinuedProcessingTask` (aşama 5).
