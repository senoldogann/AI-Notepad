# ElevenLabs tarzı yeniden tasarım — uygulama planı

Kullanıcı onayı (2026-10-26): taslaktaki yön; kayıt paneli de süt beyazı kart; ElevenLabs koyusu da olsun; yazı Inter.

## Tasarım değerleri (elevenlabs.io stil dosyalarından)

| Değer | Açık | Koyu |
|---|---|---|
| Zemin ("eggshell") | `#FDFCFC` | `#0A0A0A` |
| Kart | `#FFFFFF` | `#141414` |
| Çerçeve | `#E5E5E5` | `#262626` |
| Soluk yüzey | `#F5F5F5` | `#1C1C1C` |
| Seçili satır | `#EFEEED` | `#232323` |
| Yazı | `#0A0A0A` | `#FAFAFA` |
| Soluk yazı | `#737373` | `#A3A3A3` |
| Ana düğme | `#171717` zemin, `#FAFAFA` yazı | `#FAFAFA` zemin, `#0A0A0A` yazı |

Köşe: kart 14, hap 999, kutucuk 12. Gölge: çok hafif (0 1 2 / 0 6 20, %4–5). Başlıklar ince (400), sıkı harf aralığı.

## Adımlar

1. **Değerler ve yazı:** `AINotepadUI/Theme.swift` — açık/koyu dinamik renkler (`NSColor(name:dynamicProvider:)`,
   tema anında değişir). Inter (OFL) uygulamaya gömülür, varsayılan yazı.
2. **Düğmeler:** cam düğmeler yerine ElevenLabs hapları: ana (siyah/beyaz), ikincil (beyaz, ince çerçeve), satır/simge
   hover'ları korunur; el imleci ve basma animasyonu kalır.
3. **Yüzeyler:** cam zemin ve `glassEffect` kartlar yerine eggshell zemin ve beyaz, çerçeveli kartlar (`cardSurface`).
4. **Ana pencere iskeleti:** kendi kenar çubuğu (seçili satır gri hap, "Son toplantılar" grubu, altta durum kartı),
   üst çubuk (sayfa adı, toplantılarda arama ⌘K, "Canlı panel").
5. **Ana sayfa:** ortada ince büyük başlık, kayıt çubuğu (küre, seçenek çipleri, siyah "Başlat"), araç kutucukları,
   banner karuseli (3 slayt, nokta göstergesi, kendiliğinden ilerler), gradyan kapaklı toplantı kartları ızgarası.
6. **Görevlerim:** tüm toplantılardan sana düşen işler, toplantıya göre gruplu; tıklayınca toplantı açılır.
7. **Toplantı sayfası ve liste:** hap düğmeler, nötr bölüm seçici (soluk iz, beyaz seçili), beyaz kartlar.
8. **Kayıt paneli:** süt beyazı kart, ince çerçeve; ada çentikte siyah kalır. Hazırlanma kartı beyaz.
9. **Ayarlar ve Kurulum:** eggshell zemin; panel arka planı ayarı kalkar (artık tek yüzey); varsayılan tema açık,
   vurgu turuncu.
10. **Doğrulama:** testler, derleme, açık ve koyu temada ekran kontrolü (kullanıcıya sorarak).

## Sırada bekleyenler

- Konuşmacıları sesten tanıma (SpeakerKit ses izleri; 1. aşama toplantı içi, 2. aşama son notta adların korunması).
- v0.1.1 sürümü (imzalı, noter onaylı DMG).
- Elle kabul testi (`docs/superpowers/acceptance-checklist.md`).
