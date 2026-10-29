-- İndirmelerin kaynağı (src/downloads.ts): `GET /v1/download/mac?src=<kaynak>` sitedeki düğmenin sabit adını
-- (`home-hero`, `home-cta`, `download-page`, `account`; parametresiz `direct`, tanınmayan `other`) ve isteğin Referer
-- başlığının yalnızca alan adını (yol, sorgu ve tam adres değil; yoksa boş) gün başına sayar. IP ya da başka bir
-- tanımlayıcı tutmaz; 400 gün tutulur (src/cleanup.ts).
CREATE TABLE download_sources (
  day TEXT NOT NULL,
  source TEXT NOT NULL,
  referrer_host TEXT NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (day, source, referrer_host)
);

-- İndirme sayaçlarının ağ başına günlük tekilleştirmesi: aynı ağdan aynı gün gelen tekrar indirmeler (ve döngüyle
-- çağrılan adres) sayaçlara yazmaz, yalnızca yönlendirilir. `visitor_hash` = HMAC(sır, gün + IP; IPv6'da /64 önek):
-- günler arasında bağlanamaz, IP'ye geri çevrilemez; ertesi gün silinir (src/cleanup.ts).
CREATE TABLE download_visitors (
  day TEXT NOT NULL,
  visitor_hash TEXT NOT NULL,
  PRIMARY KEY (day, visitor_hash)
);
