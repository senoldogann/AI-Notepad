// Sayfanın sonunda çekme: en altta aşağı kaydırma (tekerlek, iz dörtgeni ya da dokunma) sürdükçe sayfanın içeriği
// (`#page-shell`) dirençle yukarı kayar ve arkadaki katman (PullReveal.astro) görünür; kaydırma durunca ya da parmak
// kalkınca içerik yaylanarak yerine döner. Yapışkan üst çubuk ters yönde aynı kadar kaydırılır, yerinde kalır. Yalnızca
// `transform` değişir (yerleşim yeniden hesaplanmaz).
//
// Ne zaman çalışmaz: hareketi azaltma açıksa (çalışırken değişirse hemen bırakır), sayfa kısa ise (en çok kaymadan az
// kaydırılabiliyorsa), yakınlaştırma hareketinde (`ctrlKey`, çok parmak), olay açık bir `<dialog>`, `<textarea>`,
// `<select>` içinden ya da hâlâ aşağı kaydırılabilen bir kaydırma alanından geliyorsa.
//
// Tarayıcının kendi esneme efekti yalnızca bu davranış etkinken ve sayfa en üstte değilken kapanır (`html.pull-armed`,
// global.css): en üstte telefonun "çekip yenile"si, diğer sayfalarda ve hareketi azaltanlarda doğal esneme sürer.
import { element } from "./dom";

/** En çok kayma (piksel; PullReveal.astro katman yüksekliğiyle aynı) ve direnç: kayma `maxPull * (1 - e^(-toplam / resistance))`. */
const maxPull: number = 170;
const resistance: number = 240;
/** Son tekerlek olayından bu kadar sonra bırakılmış sayılır (ms). */
const wheelReleaseMs: number = 140;
/** Yaylanma süresi (global.css `.is-springing` geçişiyle aynı). */
const springMs: number = 560;
/** Sayfa sonuna bu kadar yakınsa (piksel) "en altta" sayılır. */
const bottomTolerance: number = 2;
/** Satır kipindeki tekerlek olayında bir satırın piksel karşılığı (Firefox fare tekerleği). */
const linePixels: number = 40;

/** Toplam çekmeden kaymayı hesaplar (dirençli, `maxPull`'a yaklaşır). Saf fonksiyondur. */
function pullOffset(total: number): number {
  return maxPull * (1 - Math.exp(-Math.max(0, total) / resistance));
}

/** Tekerlek olayının dikey miktarını piksele çevirir (satır ve sayfa kipleri). */
function wheelPixels(event: WheelEvent): number {
  if (event.deltaMode === WheelEvent.DOM_DELTA_LINE) {
    return event.deltaY * linePixels;
  }
  if (event.deltaMode === WheelEvent.DOM_DELTA_PAGE) {
    return event.deltaY * window.innerHeight;
  }
  return event.deltaY;
}

/** Sayfa, çekme anlamlı olacak kadar uzun mu (en çok kaymadan fazla kaydırılabiliyor mu). */
function pageIsLong(): boolean {
  return document.documentElement.scrollHeight > window.innerHeight + maxPull;
}

/** Sayfa en altta mı. */
function atBottom(): boolean {
  return window.scrollY + window.innerHeight >= document.documentElement.scrollHeight - bottomTolerance;
}

/** Öğe kendi içinde hâlâ aşağı kaydırılabilen bir kaydırma alanı mı. */
function scrollsDown(node: Element): boolean {
  const overflowY: string = window.getComputedStyle(node).overflowY;
  const scrollable: boolean = overflowY === "auto" || overflowY === "scroll" || overflowY === "overlay";
  return scrollable && node.scrollTop + node.clientHeight < node.scrollHeight - 1;
}

/**
 * Aşağı kaydırma olayı sayfaya değil, hedefin kendisine ait mi: hedef açık bir `<dialog>`, `<textarea>` ya da `<select>`
 * içinde, ya da hedefle sayfa arasında hâlâ aşağı kaydırılabilen bir alan var.
 */
function ownedByInnerScroller(target: EventTarget | null): boolean {
  if (!(target instanceof Element)) {
    return false;
  }
  if (target.closest("dialog[open], textarea, select") !== null) {
    return true;
  }
  for (let node: Element | null = target; node !== null && node !== document.body && node !== document.documentElement; node = node.parentElement) {
    if (scrollsDown(node)) {
      return true;
    }
  }
  return false;
}

/** Davranışı bağlar. */
function main(): void {
  const shell: HTMLElement = element("page-shell", HTMLElement);
  const header: HTMLElement = element("site-header", HTMLElement);
  const layer: HTMLElement = element("pull-reveal", HTMLElement);
  const root: HTMLElement = document.documentElement;
  const reducedMotion: MediaQueryList = window.matchMedia("(prefers-reduced-motion: reduce)");
  let total: number = 0;
  let releaseTimer: number | null = null;
  let springTimer: number | null = null;
  let touchY: number | null = null;
  let touchTarget: EventTarget | null = null;

  const enabled = (): boolean => !reducedMotion.matches && pageIsLong();

  /** Kaymayı içeriğe, ters kaymayı üst çubuğa ve çekme oranını katmana yazar. */
  const applyPull = (): void => {
    const offset: number = pullOffset(total);
    shell.style.transform = offset === 0 ? "" : `translate3d(0, ${-offset}px, 0)`;
    header.style.transform = offset === 0 ? "" : `translate3d(0, ${offset}px, 0)`;
    layer.style.setProperty("--pull", (offset / maxPull).toFixed(3));
  };

  /** Doğal esnemeyi yalnızca etkinken ve sayfa en üstte değilken kapatır. */
  const updateArmed = (): void => {
    root.classList.toggle("pull-armed", enabled() && window.scrollY > 0);
  };

  const clearTimers = (): void => {
    if (releaseTimer !== null) {
      window.clearTimeout(releaseTimer);
      releaseTimer = null;
    }
    if (springTimer !== null) {
      window.clearTimeout(springTimer);
      springTimer = null;
    }
  };

  /** Bırakır: içerik yaylanarak yerine döner. */
  const release = (): void => {
    if (releaseTimer !== null) {
      window.clearTimeout(releaseTimer);
      releaseTimer = null;
    }
    if (total === 0) {
      return;
    }
    total = 0;
    root.classList.remove("is-pulling");
    root.classList.add("is-springing");
    applyPull();
    springTimer = window.setTimeout((): void => {
      root.classList.remove("is-springing");
      springTimer = null;
    }, springMs);
  };

  /** Geçişsiz, hemen sıfırlar (hareketi azaltma açıldığında). */
  const reset = (): void => {
    clearTimers();
    total = 0;
    touchY = null;
    root.classList.remove("is-pulling", "is-springing");
    applyPull();
    updateArmed();
  };

  const pull = (delta: number): void => {
    if (springTimer !== null) {
      window.clearTimeout(springTimer);
      springTimer = null;
      root.classList.remove("is-springing");
    }
    total += delta;
    root.classList.add("is-pulling");
    applyPull();
  };

  window.addEventListener(
    "wheel",
    (event: WheelEvent): void => {
      const delta: number = wheelPixels(event);
      if (event.ctrlKey || Math.abs(event.deltaX) > Math.abs(event.deltaY)) {
        return;
      }
      if (delta < 0) {
        release();
        return;
      }
      if (delta > 0 && enabled() && atBottom() && !ownedByInnerScroller(event.target)) {
        pull(delta);
        if (releaseTimer !== null) {
          window.clearTimeout(releaseTimer);
        }
        releaseTimer = window.setTimeout(release, wheelReleaseMs);
      }
    },
    { passive: true },
  );

  window.addEventListener(
    "touchstart",
    (event: TouchEvent): void => {
      touchY = event.touches.length === 1 ? (event.touches[0]?.clientY ?? null) : null;
      touchTarget = event.target;
    },
    { passive: true },
  );
  window.addEventListener(
    "touchmove",
    (event: TouchEvent): void => {
      const y: number | undefined = event.touches[0]?.clientY;
      if (event.touches.length !== 1 || touchY === null || y === undefined) {
        touchY = null;
        release();
        return;
      }
      const delta: number = touchY - y;
      touchY = y;
      if (delta > 0 && enabled() && atBottom() && !ownedByInnerScroller(touchTarget)) {
        pull(delta);
      } else if (delta < 0 && total > 0) {
        total = Math.max(0, total + delta);
        applyPull();
      }
    },
    { passive: true },
  );
  const endTouch = (): void => {
    touchY = null;
    touchTarget = null;
    release();
  };
  window.addEventListener("touchend", endTouch, { passive: true });
  window.addEventListener("touchcancel", endTouch, { passive: true });

  window.addEventListener("scroll", updateArmed, { passive: true });
  window.addEventListener("resize", updateArmed, { passive: true });
  reducedMotion.addEventListener("change", reset);
  updateArmed();
}

main();
