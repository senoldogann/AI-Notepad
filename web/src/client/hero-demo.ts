// Ana sayfadaki ürün gösterimi (HeroDemo.astro) tamamen CSS animasyonudur; bu betik yalnızca gösterim ekranda değilken
// ya da sekme gizliyken animasyonları duraklatır (`data-paused`), boşa iş yapılmaz.
import { element } from "./dom";

/** Gösterimi görünürlüğe göre duraklatır ya da sürdürür. */
function main(): void {
  const demo: HTMLElement = element("hero-demo", HTMLElement);
  let onScreen: boolean = true;
  const update = (): void => {
    demo.toggleAttribute("data-paused", !onScreen || document.hidden);
  };
  new IntersectionObserver((entries: IntersectionObserverEntry[]): void => {
    for (const entry of entries) {
      onScreen = entry.isIntersecting;
    }
    update();
  }).observe(demo);
  document.addEventListener("visibilitychange", update);
  update();
}

main();
