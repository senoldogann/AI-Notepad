// Dile özgü olmayan adresler (kök, Stripe ve e-posta dönüşleri): okuyanın dilindeki sayfaya geçer; sorgu dizgisi ve
// `#` parçası (ör. giriş jetonu) korunur. Hedefler sayfadaki bağlantılardır (`data-lang`), betik yoksa onlar görünür.
import { element } from "./dom";
import { preferredLang } from "./lang";

/** Sayfayı başlatır. */
function main(): void {
  const lang: string = preferredLang();
  const link: HTMLAnchorElement = element(`lang-target-${lang}`, HTMLAnchorElement);
  window.location.replace(`${link.pathname}${window.location.search}${window.location.hash}`);
}

main();
