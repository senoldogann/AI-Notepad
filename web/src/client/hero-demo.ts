// Ana sayfadaki ürün gösterimi (HeroDemo.astro) tamamen CSS animasyonudur. Bu betik:
// - gösterim ekranda değilken ya da sekme gizliyken animasyonları duraklatır (`data-paused`), boşa iş yapılmaz;
// - köşedeki düğmeyi gösterir: duraklat (`data-user-paused`), sürdür ve gösterim bitince (üç tur, bitmiş notta durur:
//   `data-finished`) baştan oynat (WCAG 2.2.2). Hareket azaltılmışsa düğme CSS ile gizlidir, gösterim durgundur.
import { dataValue, element } from "./dom";

/** Düğmenin durumu: gösterim oynuyor, kullanıcı duraklattı ya da gösterim bitti. */
type DemoState = "playing" | "paused" | "finished";

/** Turu sayan ana animasyonun adı (HeroDemo.astro `@keyframes demo-timer`); bitince gösterim biter. */
const finishingAnimation: string = "demo-timer";

/** Düğmeyi durumla eşler: simge (`data-state`), erişilebilir ad ve ipucu. */
function renderToggle(toggle: HTMLButtonElement, state: DemoState): void {
  const label: string = dataValue(toggle, state === "playing" ? "labelPause" : state === "paused" ? "labelPlay" : "labelReplay");
  toggle.dataset["state"] = state;
  toggle.setAttribute("aria-label", label);
  toggle.title = label;
}

/** Animasyonları baştan başlatır: bir kare kaldırılıp geri verilir (`data-restart`). */
function restart(demo: HTMLElement): void {
  demo.toggleAttribute("data-restart", true);
  // Yerleşimi okumak kaldırmayı uygulatır; özellik silinince animasyonlar sıfırdan başlar.
  void demo.offsetWidth;
  demo.toggleAttribute("data-restart", false);
}

/** Davranışı bağlar. */
function main(): void {
  const demo: HTMLElement = element("hero-demo", HTMLElement);
  const toggle: HTMLButtonElement = element("hero-demo-toggle", HTMLButtonElement);
  let onScreen: boolean = true;
  let state: DemoState = "playing";

  const updateVisibility = (): void => {
    demo.toggleAttribute("data-paused", !onScreen || document.hidden);
  };
  const setState = (next: DemoState): void => {
    state = next;
    demo.toggleAttribute("data-user-paused", next === "paused");
    demo.toggleAttribute("data-finished", next === "finished");
    renderToggle(toggle, next);
  };

  new IntersectionObserver((entries: IntersectionObserverEntry[]): void => {
    for (const entry of entries) {
      onScreen = entry.isIntersecting;
    }
    updateVisibility();
  }).observe(demo);
  document.addEventListener("visibilitychange", updateVisibility);

  demo.addEventListener("animationend", (event: AnimationEvent): void => {
    if (event.animationName === finishingAnimation) {
      setState("finished");
    }
  });
  toggle.addEventListener("click", (): void => {
    if (state === "playing") {
      setState("paused");
    } else if (state === "paused") {
      setState("playing");
    } else {
      setState("playing");
      restart(demo);
    }
  });

  updateVisibility();
  setState("playing");
  toggle.hidden = false;
}

main();
