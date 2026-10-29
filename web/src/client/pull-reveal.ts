// Sayfanın sonunda çekme: en altta aşağı kaydırma (tekerlek, iz dörtgeni ya da dokunma) sürdükçe sayfa (`#page-shell`)
// dirençle yukarı kayar ve arkadaki katman (PullReveal.astro) görünür; kaydırma durunca ya da parmak kalkınca sayfa
// yaylanarak yerine döner. Tarayıcının kendi esneme efekti global.css'te kapalıdır, yerine bu çalışır. Hareketi
// azaltmayı seçenlerde hiç çalışmaz. Yalnızca `transform` değişir (yerleşim yeniden hesaplanmaz).
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

/** Toplam çekmeden kaymayı hesaplar (dirençli, `maxPull`'a yaklaşır). Saf fonksiyondur. */
function pullOffset(total: number): number {
  return maxPull * (1 - Math.exp(-Math.max(0, total) / resistance));
}

/** Sayfa en altta mı. */
function atBottom(): boolean {
  return window.scrollY + window.innerHeight >= document.documentElement.scrollHeight - bottomTolerance;
}

/** Çekme durumunu sayfaya yazar. */
function applyPull(shell: HTMLElement, root: HTMLElement, total: number): void {
  const offset: number = pullOffset(total);
  shell.style.transform = `translate3d(0, ${-offset}px, 0)`;
  root.style.setProperty("--pull", (offset / maxPull).toFixed(3));
}

/** Davranışı bağlar. */
function main(): void {
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    return;
  }
  const shell: HTMLElement = element("page-shell", HTMLElement);
  const root: HTMLElement = document.documentElement;
  let total: number = 0;
  let releaseTimer: number | null = null;
  let springTimer: number | null = null;
  let touchY: number | null = null;

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
    shell.style.transform = "";
    root.style.setProperty("--pull", "0");
    springTimer = window.setTimeout((): void => {
      root.classList.remove("is-springing");
      springTimer = null;
    }, springMs);
  };

  const pull = (delta: number): void => {
    if (springTimer !== null) {
      window.clearTimeout(springTimer);
      springTimer = null;
      root.classList.remove("is-springing");
    }
    total += delta;
    root.classList.add("is-pulling");
    applyPull(shell, root, total);
  };

  window.addEventListener(
    "wheel",
    (event: WheelEvent): void => {
      if (event.deltaY > 0 && atBottom()) {
        pull(event.deltaY);
        if (releaseTimer !== null) {
          window.clearTimeout(releaseTimer);
        }
        releaseTimer = window.setTimeout(release, wheelReleaseMs);
      } else if (event.deltaY < 0) {
        release();
      }
    },
    { passive: true },
  );

  window.addEventListener(
    "touchstart",
    (event: TouchEvent): void => {
      touchY = event.touches[0]?.clientY ?? null;
    },
    { passive: true },
  );
  window.addEventListener(
    "touchmove",
    (event: TouchEvent): void => {
      const y: number | undefined = event.touches[0]?.clientY;
      if (touchY === null || y === undefined) {
        return;
      }
      const delta: number = touchY - y;
      touchY = y;
      if (delta > 0 && atBottom()) {
        pull(delta);
      } else if (delta < 0 && total > 0) {
        total = Math.max(0, total + delta);
        applyPull(shell, root, total);
      }
    },
    { passive: true },
  );
  const endTouch = (): void => {
    touchY = null;
    release();
  };
  window.addEventListener("touchend", endTouch, { passive: true });
  window.addEventListener("touchcancel", endTouch, { passive: true });
}

main();
