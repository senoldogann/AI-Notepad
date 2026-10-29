-- Deepgram jetonlarının kısa süreli sınırı (src/deepgram.ts `deepgramGrantsPerWindow`): sunucu akışı göremediği için
-- aynı anda açılabilecek akış sayısı, bir toplantıya kısa bir pencerede verilen jeton sayısıyla sınırlanır. Pencere
-- `window_started_at`'ta başlar; içinde verilen jeton `window_grants`. Eski satırlarda 0: ilk jetonda pencere yeniden başlar.
ALTER TABLE deepgram_live_meetings ADD COLUMN window_started_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE deepgram_live_meetings ADD COLUMN window_grants INTEGER NOT NULL DEFAULT 0;
