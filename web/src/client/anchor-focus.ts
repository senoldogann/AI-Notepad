// Sayfa içi bağlantılar (#features, içindekiler, SSS): kaydırmayı tarayıcı yapar (global.css `scroll-behavior`,
// hareket azaltılmışsa atlar); bu betik klavye kullanıcıları için odağı da hedef bölüme taşır. Odaklanamayan hedefe
// `tabindex="-1"` verilir; odak kaydırmayı tetiklemez (`preventScroll`), yumuşak kaydırma kesilmez.

/** Bağlantı bu sayfadaki bir çapaya mı gidiyor; öyleyse hedef öğe, değilse null. */
function inPageTarget(link: HTMLAnchorElement): HTMLElement | null {
  if (link.hash === "" || link.origin !== window.location.origin || link.pathname !== window.location.pathname) {
    return null;
  }
  return document.getElementById(decodeURIComponent(link.hash.slice(1)));
}

/** Davranışı bağlar. */
function main(): void {
  document.addEventListener("click", (event: MouseEvent): void => {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
      return;
    }
    const link: HTMLAnchorElement | null = event.target instanceof Element ? event.target.closest<HTMLAnchorElement>("a[href*='#']") : null;
    const target: HTMLElement | null = link === null ? null : inPageTarget(link);
    if (target === null) {
      return;
    }
    if (!target.hasAttribute("tabindex") && target.tabIndex < 0) {
      target.setAttribute("tabindex", "-1");
    }
    target.focus({ preventScroll: true });
  });
}

main();
