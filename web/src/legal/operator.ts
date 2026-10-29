// Hizmeti sunan işletme (veri sorumlusu): yasal metinler, alt bilgi ve iletişim bağlantıları buradan okur. İşletme
// bilgisi değişince yalnızca burası değişir.

/** İşletme bilgileri. */
export interface Operator {
  /** Ticari unvan. */
  readonly name: string;
  /** Hukuki biçim (Fince adıyla birlikte). */
  readonly legalForm: string;
  /** Fin işletme kimliği (Y-tunnus). */
  readonly businessId: string;
  /** Posta adresi. */
  readonly address: string;
  /** Gizlilik, destek ve hukuki iletişim adresi. */
  readonly email: string;
}

/** Hizmeti sunan işletme. */
export const operator: Operator = {
  name: "T:mi Aslan Dogan Marketing",
  legalForm: "a Finnish sole proprietorship (yksityinen elinkeinonharjoittaja)",
  businessId: "3346878-5",
  address: "Sarvivälkkeentie 3 C 27, 90240 Oulu, Finland",
  email: "contact@senoldogan.dev",
};

/** Yasal metinlerin son güncellenme tarihi (ISO). */
export const legalUpdated: string = "2026-10-29";
