-- Deepgram canlı metin bütçesi (src/deepgram.ts): Deepgram'a doğrudan akış istemciden gider, sunucu akışı görmez. Her
-- toplantının ilk jetonunda toplantının kalan en çok süresi (iki akış: "Sen" ve "Diğerleri") peşin sayılır, toplantı
-- bitince gerçek süreye indirilir (`settled_at`). Toplam ücretsiz kredi bütçesine (`DEEPGRAM_BUDGET_USD`) sayılan
-- tahmin `charged_seconds` toplamıdır; satırlar bütçe ömür boyu olduğu için silinmez ve kullanıcıya bağlanmaz (toplantı
-- silinince kimlik hiçbir şeye bağlanamaz).
CREATE TABLE deepgram_live_meetings (
  meeting_id TEXT PRIMARY KEY,
  -- Bu toplantı için verilen jeton sayısı (her bağlantı ve yeniden bağlanma bir jeton).
  grants INTEGER NOT NULL,
  first_grant_at INTEGER NOT NULL,
  -- Bütçeye sayılan akış saniyesi (tüm akışlar toplamı).
  charged_seconds INTEGER NOT NULL,
  -- Gerçek süreye indirildiği an; toplantı sürüyorsa null.
  settled_at INTEGER
);
CREATE INDEX deepgram_live_meetings_unsettled ON deepgram_live_meetings(settled_at);
