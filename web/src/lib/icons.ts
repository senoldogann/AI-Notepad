// Sitenin simge takımı: 24×24 ızgara, 1,5 px çizgi, yuvarlak uçlar, `currentColor`. Çizimler bu site için elle
// yazılmıştır (dış kaynak yok). `apple` dolu bir işarettir (Apple logosu, Simple Icons CC0 yolu).

/** Simge adları. */
export type IconName =
  | "apple"
  | "arrow-right"
  | "calendar"
  | "card"
  | "chart"
  | "check"
  | "check-circle"
  | "chip"
  | "clock"
  | "disk"
  | "download"
  | "gift"
  | "globe"
  | "inbox"
  | "laptop"
  | "lock"
  | "mail"
  | "message"
  | "moon"
  | "note"
  | "plug"
  | "refresh"
  | "rewind"
  | "search"
  | "sparkle"
  | "sun"
  | "timer"
  | "tokens"
  | "translate"
  | "user"
  | "users"
  | "wallet"
  | "waveform";

/** Çizgi simgesi mi dolu işaret mi. */
export type IconStyle = "stroke" | "fill";

/** Simgenin SVG içeriği (24×24 görünüm kutusu) ve çizim biçimi. */
export interface IconShape {
  readonly style: IconStyle;
  readonly body: string;
}

/** Simgelerin çizimleri. */
export const icons: Readonly<Record<IconName, IconShape>> = {
  apple: {
    style: "fill",
    body: '<path d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701"/>',
  },
  "arrow-right": { style: "stroke", body: '<path d="M4.5 12h15M13.5 6l6 6-6 6"/>' },
  calendar: {
    style: "stroke",
    body: '<rect x="3.75" y="5.25" width="16.5" height="15" rx="3"/><path d="M3.75 10.25h16.5M8.25 3v4M15.75 3v4"/><path d="M8 14.5h.01M12 14.5h.01M16 14.5h.01M8 17.5h.01M12 17.5h.01"/>',
  },
  card: { style: "stroke", body: '<rect x="2.75" y="5.25" width="18.5" height="13.5" rx="3"/><path d="M2.75 10h18.5M6.5 15h3.5"/>' },
  chart: { style: "stroke", body: '<path d="M4 20h16"/><rect x="5.5" y="11" width="3" height="6.5" rx="1"/><rect x="10.5" y="6.5" width="3" height="11" rx="1"/><rect x="15.5" y="13.5" width="3" height="4" rx="1"/>' },
  check: { style: "stroke", body: '<path d="m5 12.5 4.5 4.5L19 7.5"/>' },
  "check-circle": { style: "stroke", body: '<circle cx="12" cy="12" r="8.75"/><path d="m8.25 12.25 2.5 2.5 5-5"/>' },
  chip: {
    style: "stroke",
    body: '<rect x="6" y="6" width="12" height="12" rx="2.5"/><rect x="9.5" y="9.5" width="5" height="5" rx="1"/><path d="M9.5 3v3M14.5 3v3M9.5 18v3M14.5 18v3M3 9.5h3M3 14.5h3M18 9.5h3M18 14.5h3"/>',
  },
  clock: { style: "stroke", body: '<circle cx="12" cy="12" r="8.75"/><path d="M12 7.5V12l3 2"/>' },
  disk: {
    style: "stroke",
    body: '<path d="M3.75 13.5 6.2 6.1A2.5 2.5 0 0 1 8.57 4.5h6.86a2.5 2.5 0 0 1 2.37 1.6l2.45 7.4"/><rect x="3.75" y="13.5" width="16.5" height="6" rx="2.5"/><path d="M16.5 16.5h.01"/>',
  },
  download: { style: "stroke", body: '<path d="M12 4v11m0 0 4.5-4.5M12 15l-4.5-4.5M5 19.5h14"/>' },
  gift: {
    style: "stroke",
    body: '<rect x="3.75" y="8.25" width="16.5" height="4" rx="1.25"/><path d="M5.25 12.25v6.5a1.5 1.5 0 0 0 1.5 1.5h10.5a1.5 1.5 0 0 0 1.5-1.5v-6.5M12 8.25v12M12 8.25C10.8 5 8 4 7.1 5.4c-.8 1.3.8 2.85 4.9 2.85Zm0 0c1.2-3.25 4-4.25 4.9-2.85.8 1.3-.8 2.85-4.9 2.85Z"/>',
  },
  globe: { style: "stroke", body: '<circle cx="12" cy="12" r="8.75"/><path d="M3.25 12h17.5M12 3.25c2.3 2.4 3.5 5.3 3.5 8.75s-1.2 6.35-3.5 8.75c-2.3-2.4-3.5-5.3-3.5-8.75S9.7 5.65 12 3.25Z"/>' },
  inbox: { style: "stroke", body: '<path d="M3.75 13.5h4.5l1.5 2.5h4.5l1.5-2.5h4.5"/><path d="M5.6 6.1A2.5 2.5 0 0 1 7.9 4.5h8.2a2.5 2.5 0 0 1 2.3 1.6l1.85 5.15v6a2.25 2.25 0 0 1-2.25 2.25H6a2.25 2.25 0 0 1-2.25-2.25v-6Z"/>' },
  laptop: { style: "stroke", body: '<rect x="4.75" y="5" width="14.5" height="10" rx="2"/><path d="M2.75 18.75h18.5"/>' },
  lock: { style: "stroke", body: '<rect x="5" y="10.5" width="14" height="10" rx="2.5"/><path d="M8.25 10.5V7.75a3.75 3.75 0 0 1 7.5 0v2.75M12 14.5v2"/>' },
  mail: { style: "stroke", body: '<rect x="3" y="5.25" width="18" height="13.5" rx="3"/><path d="m4 7 8 6 8-6"/>' },
  message: { style: "stroke", body: '<path d="M20.25 11.6c0 4.2-3.7 7.4-8.25 7.4-1.15 0-2.25-.2-3.25-.57L4.5 19.75l1.2-3.5c-1.2-1.3-1.95-2.9-1.95-4.65 0-4.1 3.7-7.35 8.25-7.35s8.25 3.25 8.25 7.35Z"/>' },
  moon: { style: "stroke", body: '<path d="M19.5 14.6A8 8 0 0 1 9.4 4.5a8 8 0 1 0 10.1 10.1Z"/>' },
  note: { style: "stroke", body: '<path d="M14.25 3.75H7.5a2.25 2.25 0 0 0-2.25 2.25v12a2.25 2.25 0 0 0 2.25 2.25h9a2.25 2.25 0 0 0 2.25-2.25V8.25Z"/><path d="M14.25 3.75v4.5h4.5M8.75 12.5h6.5M8.75 16h4"/>' },
  plug: { style: "stroke", body: '<path d="M9 3.75V7.5M15 3.75V7.5M6.75 7.5h10.5V11a5.25 5.25 0 0 1-10.5 0Z"/><path d="M12 16.25v4"/>' },
  refresh: { style: "stroke", body: '<path d="M19.5 12a7.5 7.5 0 0 1-13.1 5M4.5 12a7.5 7.5 0 0 1 13.1-5"/><path d="M17.75 3.5V7.2h-3.7M6.25 20.5v-3.7h3.7"/>' },
  rewind: { style: "stroke", body: '<path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3L4.5 9"/><path d="M4.5 4.5V9H9M12 8.25V12l2.5 1.75"/>' },
  search: { style: "stroke", body: '<circle cx="10.75" cy="10.75" r="6.5"/><path d="m15.5 15.5 4.75 4.75"/>' },
  sparkle: { style: "stroke", body: '<path d="M12 3.5c.6 4.4 2.1 5.9 6.5 6.5-4.4.6-5.9 2.1-6.5 6.5-.6-4.4-2.1-5.9-6.5-6.5 4.4-.6 5.9-2.1 6.5-6.5Z"/><path d="M18.5 15.5c.25 1.75.75 2.25 2.5 2.5-1.75.25-2.25.75-2.5 2.5-.25-1.75-.75-2.25-2.5-2.5 1.75-.25 2.25-.75 2.5-2.5Z"/>' },
  sun: { style: "stroke", body: '<circle cx="12" cy="12" r="4"/><path d="M12 2.75v1.5M12 19.75v1.5M2.75 12h1.5M19.75 12h1.5M5.46 5.46l1.06 1.06M17.48 17.48l1.06 1.06M5.46 18.54l1.06-1.06M17.48 6.52l1.06-1.06"/>' },
  timer: { style: "stroke", body: '<circle cx="12" cy="13.25" r="7.25"/><path d="M12 9.5v3.75M9.75 2.75h4.5M18.25 6.75l1.25-1.25"/>' },
  tokens: { style: "stroke", body: '<ellipse cx="12" cy="6.5" rx="7" ry="2.75"/><path d="M5 6.5v5.5c0 1.5 3.1 2.75 7 2.75s7-1.25 7-2.75V6.5M5 12v5.5c0 1.5 3.1 2.75 7 2.75s7-1.25 7-2.75V12"/>' },
  translate: { style: "stroke", body: '<path d="M3.75 5.75h9M8.25 3.75v2M5.75 5.75c.6 3.4 2.6 5.9 5.75 7.25M10.75 5.75c-.6 3.4-2.6 5.9-5.75 7.25"/><path d="m12.25 20.25 3.75-9 3.75 9M13.6 17h4.8"/>' },
  user: { style: "stroke", body: '<circle cx="12" cy="8.25" r="3.75"/><path d="M4.75 20c.9-3.6 3.75-5.5 7.25-5.5s6.35 1.9 7.25 5.5"/>' },
  users: { style: "stroke", body: '<circle cx="9.5" cy="8.5" r="3.5"/><path d="M3.25 19.5c.8-3.3 3.2-5 6.25-5s5.45 1.7 6.25 5M15.5 5.2a3.5 3.5 0 0 1 0 6.6M17.5 14.7c1.6.6 2.75 2.2 3.25 4.8"/>' },
  wallet: { style: "stroke", body: '<path d="M18.75 7.5V6a2.25 2.25 0 0 0-2.25-2.25H6A2.25 2.25 0 0 0 3.75 6v12A2.25 2.25 0 0 0 6 20.25h12.75A1.5 1.5 0 0 0 20.25 18.75v-9.75a1.5 1.5 0 0 0-1.5-1.5H6"/><path d="M16.5 14h.01"/>' },
  waveform: { style: "stroke", body: '<path d="M3.5 12h1M7 8.5v7M10.5 5v14M14 8v8M17.5 10v4M20.5 12h.01"/>' },
};
