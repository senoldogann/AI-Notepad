-- Yenileme jetonunun yerine geçen jeton (özet): hemen önceki jeton 30 saniye içinde yeniden sunulursa (yanıtı
-- kaybolan yenileme) aile düşürülmez, yerine geçen jeton değiştirilir (src/auth/tokens.ts).
ALTER TABLE refresh_tokens ADD COLUMN replaced_by TEXT;
