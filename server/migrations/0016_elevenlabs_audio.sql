-- ElevenLabs'e giden ses saniyesinin günlük toplamı (hesaptan bağımsız; hesap silinince kalır): aylık kredi planının
-- dönem kullanımı buradan hesaplanır (src/elevenLabsCapacity.ts). Var olan günler toplantılardan doldurulamaz (silinmiş
-- hesapların toplantıları yok): sayaç bu göçle başlar.
ALTER TABLE daily_spend ADD COLUMN audio_seconds REAL NOT NULL DEFAULT 0;
