-- Deepgram bütçesinin artımlı toplamı (src/deepgram.ts): bütçe denetimi her `GET /v1/me`'de ve her toplantının ilk
-- jetonunda `deepgram_live_meetings` tablosunun tamamını topluyordu (satırlar hiç silinmez, okuma satır sayısıyla
-- büyür). Tek satırlık toplam tabloyla aynı soru tek satır okur. Toplamı tetikleyiciler tutar: tabloya ekleme, peşin
-- tahminin gerçek süreye indirilmesi (`charged_seconds`, `settled_at`) ve silme toplamı aynı işlemde değiştirir;
-- böylece toplam her an `SUM(charged_seconds)` ile aynıdır (kod yolu unutulamaz). Var olan satırlar aşağıda toplanır.
CREATE TABLE deepgram_budget (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  -- Bütçeye sayılan akış saniyesi (`SUM(deepgram_live_meetings.charged_seconds)`).
  charged_seconds INTEGER NOT NULL,
  -- Jeton almış toplantı sayısı ve henüz gerçek süreye indirilmemiş olanlar.
  meetings INTEGER NOT NULL,
  open_meetings INTEGER NOT NULL
);

INSERT INTO deepgram_budget (id, charged_seconds, meetings, open_meetings)
SELECT 1, COALESCE(SUM(charged_seconds), 0), COUNT(*), COALESCE(SUM(CASE WHEN settled_at IS NULL THEN 1 ELSE 0 END), 0)
FROM deepgram_live_meetings;

CREATE TRIGGER deepgram_budget_after_insert AFTER INSERT ON deepgram_live_meetings
BEGIN
  UPDATE deepgram_budget
  SET charged_seconds = charged_seconds + NEW.charged_seconds,
    meetings = meetings + 1,
    open_meetings = open_meetings + (CASE WHEN NEW.settled_at IS NULL THEN 1 ELSE 0 END)
  WHERE id = 1;
END;

CREATE TRIGGER deepgram_budget_after_update AFTER UPDATE OF charged_seconds, settled_at ON deepgram_live_meetings
BEGIN
  UPDATE deepgram_budget
  SET charged_seconds = charged_seconds - OLD.charged_seconds + NEW.charged_seconds,
    open_meetings = open_meetings - (CASE WHEN OLD.settled_at IS NULL THEN 1 ELSE 0 END) + (CASE WHEN NEW.settled_at IS NULL THEN 1 ELSE 0 END)
  WHERE id = 1;
END;

CREATE TRIGGER deepgram_budget_after_delete AFTER DELETE ON deepgram_live_meetings
BEGIN
  UPDATE deepgram_budget
  SET charged_seconds = charged_seconds - OLD.charged_seconds,
    meetings = meetings - 1,
    open_meetings = open_meetings - (CASE WHEN OLD.settled_at IS NULL THEN 1 ELSE 0 END)
  WHERE id = 1;
END;
