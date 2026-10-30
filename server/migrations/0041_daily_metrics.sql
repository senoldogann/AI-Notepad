-- Günlük anlık görüntü (yönetim paneli "Trends"; src/dailyMetrics.ts): günlük Cron her gece biten UTC gününün toplamlarını
-- ve gün sonundaki durumu tek satıra yazar. Kaynak tabloların saklama süreleri (harcama 90 gün, toplantılar 13 ay)
-- dolsa da eğilimler kalır. Yalnızca toplamlar: kullanıcı, IP ya da içerik tutmaz; 5 yıl tutulur (src/cleanup.ts).
-- Aynı gün yeniden yazılırsa (Cron'un yeniden çalışması) satır güncellenir.
CREATE TABLE daily_metrics (
  day TEXT PRIMARY KEY,
  -- Satırın yazıldığı an (ms); durum alanları bu andaki satırlardan, gün sonu anına göre hesaplanır.
  captured_at INTEGER NOT NULL,
  -- Gün sonunda var olan hesaplar (silinenler sayılmaz) ve gün içinde açılanlar.
  users_total INTEGER NOT NULL,
  users_new INTEGER NOT NULL,
  -- Toplantı başlatan farklı hesaplar: gün içinde, son 7 ve son 30 günde (gün dahil).
  active_users_day INTEGER NOT NULL,
  active_users_7d INTEGER NOT NULL,
  active_users_30d INTEGER NOT NULL,
  -- Gün içinde başlayan toplantılar (türe göre).
  meetings_trial INTEGER NOT NULL,
  meetings_subscription INTEGER NOT NULL,
  -- Denemesi gün içinde başlayan hesaplar; gün sonunda süren ve biten (toplantıları ya da süresi dolan) denemeler.
  trials_started INTEGER NOT NULL,
  trials_active INTEGER NOT NULL,
  trials_exhausted INTEGER NOT NULL,
  -- Abonelikler gün sonunda (yönetim istatistiğiyle aynı tanımlar; src/admin.ts `subscriptionCounts`).
  subscriptions_active INTEGER NOT NULL,
  subscriptions_grace INTEGER NOT NULL,
  subscriptions_ending INTEGER NOT NULL,
  subscriptions_canceled INTEGER NOT NULL,
  subscriptions_monthly INTEGER NOT NULL,
  subscriptions_yearly INTEGER NOT NULL,
  subscriptions_complimentary INTEGER NOT NULL,
  subscriptions_free_invite_month INTEGER NOT NULL,
  -- Liste fiyatıyla MRR (sent, USD): aylık × aylık fiyat + yıllık × yıllık fiyat / 12.
  mrr_list_cents INTEGER NOT NULL,
  -- Günün tahmini harcaması sağlayıcıya göre (mikro USD): Anthropic, ElevenLabs, Deepgram (gün içinde ilk jetonu
  -- alan toplantıların bütçeye sayılan akış süresi) ve toplamın deneme payı.
  spend_anthropic_micro_usd INTEGER NOT NULL,
  spend_elevenlabs_micro_usd INTEGER NOT NULL,
  spend_deepgram_micro_usd INTEGER NOT NULL,
  spend_trial_micro_usd INTEGER NOT NULL,
  -- ElevenLabs'e giden ses (saniye) ve Deepgram'a sayılan akış (saniye).
  elevenlabs_audio_seconds REAL NOT NULL,
  deepgram_stream_seconds INTEGER NOT NULL
);

-- Günlük harcamanın Anthropic payı (src/reservations.ts): `micro_usd` LLM ve ses çağrılarının toplamıdır; LLM payı ayrıca
-- tutulur, ElevenLabs payı farktır. Bu göçten önceki günlerde 0 (o günlerin harcaması ayrıştırılamaz).
ALTER TABLE daily_spend ADD COLUMN llm_micro_usd INTEGER NOT NULL DEFAULT 0;
