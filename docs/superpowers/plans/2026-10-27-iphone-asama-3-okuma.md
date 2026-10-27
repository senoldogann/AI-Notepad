# iPhone aşama 3 — Okuma

Tasarım: `docs/superpowers/specs/2026-10-27-iphone-design.md`.

## Hedef

Telefonda toplantı okunur ve dinlenir; arşive soru sorulur; görevler takip edilir. Mac'le aynı bileşenler kullanılır
(kopya kod yok).

## Adımlar

1. Ortak pakete taşınanlar: `MeetingAudioPlayer` (iOS'ta çalma oturumu), `PlaybackFollower`, `KaraokeParagraph`,
   arşiv sohbeti (`ArchiveExchange`, `ExchangeView`, `ThinkingRing`), `activeParagraphID` ve `myTasks` (çekirdek).
2. Toplantı sayfası: kapak (tarih, başlık, süre, dil, "Dinle"), Özet (senin görevlerin işaretlenebilir, özet, kararlar,
   konu akışı — dokununca oradan çalar, diğer görevler) ve Transkript (konuşmacılı ≤30 sn paragraflar; çalan paragraf
   kelime kelime vurgulu ve üst üçte birde; dokununca oradan çalar). Toplantılarda arama.
3. Mini çalar: sekme çubuğunun üstünde (`tabViewBottomAccessory`), ada dokununca toplantı açılır; kayıt başlayınca
   çalma durur. iOS en düşük sürüm 26.1 (koşullu aksesuar).
4. Sor: Mac'teki `askArchive` ve sohbet görünümü; örnek sorular, akan cevap, kaynaklar toplantıyı açar.
5. Görevlerim: açık/tamamlanan, işaret toplantıya yazılır, satır toplantıyı açar.

## Durum

- [x] 1–5. Mac: 223 + 27 test, Mac uygulaması derlenir; iOS simülatöründe çekirdek testleri ve uygulama. Simülatörde
  özet, transkriptte çalma (01:19'da 01:18 paragrafı vurgulu, mini çalar), Sor ve Görevlerim ekran görüntüsüyle bakıldı.
- Anımsatıcılar'a ekleme telefonda yok (Mac'te var); gerekirse aşama 5'te.
