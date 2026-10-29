// Üst çubuk: sekmede oturum varsa "Giriş yap" bağlantıları hesap sayfasına gider ve "Hesap" yazar.
import { dataValue, element } from "./dom";
import { hasSession } from "./session";

/** Oturum varsa giriş bağlantılarını hesap bağlantısına çevirir. */
function main(): void {
  if (!hasSession()) {
    return;
  }
  const header: HTMLElement = element("site-header", HTMLElement);
  const href: string = dataValue(header, "accountHref");
  const label: string = dataValue(header, "accountLabel");
  const current: boolean = window.location.pathname === href;
  for (const link of document.querySelectorAll<HTMLAnchorElement>("a[data-session-link]")) {
    link.href = href;
    link.textContent = label;
    if (current) {
      link.setAttribute("aria-current", "page");
    }
  }
}

main();
