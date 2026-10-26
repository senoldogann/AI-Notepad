# Rakip analizindeki eksikler — uygulama planı

Kullanıcı onayı (2026-10-26): eksiklerin hepsi en iyi seviyede, test edilerek eklenecek; iPhone uygulaması bu pakette
yok (sonraki aşama). Rakipler: Granola, Otter, Fireflies, Fathom, tl;dv, Jamie, Krisp, Read.ai, Notion, Teams/Zoom/Meet.

## Sıra

1. **Kayıt rızası hatırlatması:** kayıt başlarken panelde kısa not ve kopyalanabilir Fince/İngilizce bildirim; ayardan
   kapatılabilir.
2. **Görev takibi:** görevler tamamlandı işaretlenir (toplantıda saklanır), Görevlerim açık/tamamlanan ayrımı, tek tıkla
   Apple Anımsatıcılar'a (EventKit) gönderme, tarihli görev için hatırlatma tarihi.
3. **Paylaşım ve çıktı dili:** notun Fince/İngilizce paylaşım sürümü (LLM, saklanır), paylaş menüsü (Mail, Mesajlar,
   Notlar, Slack…), not şablonları (Genel, Birebir, Müşteri, Ders/Eğitim, Mülakat, kendi şablonun).
4. **Takvim:** EventKit ile yaklaşan toplantılar (Ana sayfa), başlamadan 1 dk önce bildirim ("Dinlemeye başla"),
   başka uygulama mikrofonu açınca öneri; kayıt etkinliğe bağlanır: başlık, katılımcı adları tanıma terimi ve konuşmacı
   adı ipucu olur.
5. **Toplantılarıma sor:** tüm yerel arşivde soru-cevap; ilgili toplantılar yerelde seçilir (anahtar sözcük puanı),
   yanıt kaynak toplantılarla, tıklayınca açılır.
6. **Kişiler:** adı verilen konuşmacılar (ses izi ve adlar) için kişi sayfası: toplantıları, konuşma süresi, görevleri.
7. **Yüz yüze toplantı modu:** sistem sesi yerine mikrofon "Diğerleri" akışına gider; konuşmacılar ayrılır.
8. **Yerel MCP sunucusu:** `AINotepad --mcp` (stdio); araçlar: toplantıları listele, ara, toplantıyı getir. Ayarlar'da
   Claude/ChatGPT için yapılandırma.
9. **Anahtarsız kullanım:** WhisperKit + Mac'teki Ollama; Ollama algılanır, önerilen model tek tıkla seçilir.
   Apple'ın cihaz üstü modeli (Foundation Models) denendi: Fince desteklenmiyor, Fince toplantıdan Türkçe notta Fince
   sözcükler kalıyor ve anlamlar kayıyor (2026-10-26 ölçümü); not modeli olarak eklenmedi.

Durum: 1–9 tamamlandı (2026-10-27).

## Sonraki aşama

- iPhone uygulaması (aynı çekirdek, yüz yüze kayıt).
