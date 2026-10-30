// @ts-check
// Açık/koyu tema. <head> içinde engelleyici, harici bir betik olarak yüklenir (CSP satır içi betiğe izin vermez): ilk
// boyamadan önce `<html data-theme>` yazılır, sayfa yanlış temada yanıp sönmez. Kullanıcı seçim yapmadıysa sistem
// tercihi izlenir; düğmeyle yapılan seçim localStorage'da kalır. Tema değişince `gistsmith:themechange` olayı yayılır
// (Turnstile parçacığı temayı buradan alır). Tarayıcı çubuğunun rengi (`<meta name="theme-color">`) de seçilen temaya
// uyar; bu yüzden Base.astro'da meta etiketleri bu betikten önce gelir. Derlenmez: TypeScript denetimi JSDoc
// tipleriyle yapılır.

(() => {
  /** Tema adı. @typedef {"light" | "dark"} Theme */

  const storageKey = "gistsmith.theme";
  const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  const root = document.documentElement;
  // Tarayıcı çubuğunun rengi; global.css `--bg` ile aynı kalmalı.
  const lightBarColor = "#fdfcfc";
  const darkBarColor = "#0a0a0a";

  /**
   * Saklanan seçim; yoksa null. Depolama kapalıysa (ör. tarayıcı ayarı) uyarı yazılır ve sistem tercihi kullanılır.
   * @returns {Theme | null}
   */
  function storedTheme() {
    try {
      const value = window.localStorage.getItem(storageKey);
      return value === "light" || value === "dark" ? value : null;
    } catch (error) {
      console.warn("theme_storage_unavailable", { error: error instanceof Error ? error.message : String(error) });
      return null;
    }
  }

  /** @returns {Theme} */
  function systemTheme() {
    return darkQuery.matches ? "dark" : "light";
  }

  /**
   * Temayı sayfaya yazar; tarayıcı çubuğunun rengini ve düğmeleri günceller. İki `theme-color` etiketi de (sistem
   * tercihine göre seçilenler) aynı renge çekilir, böylece elle seçilen tema sistem teması yerine geçer.
   * @param {Theme} theme
   */
  function apply(theme) {
    root.dataset["theme"] = theme;
    for (const meta of document.querySelectorAll('meta[name="theme-color"]')) {
      meta.setAttribute("content", theme === "dark" ? darkBarColor : lightBarColor);
    }
    for (const button of document.querySelectorAll("[data-theme-toggle]")) {
      button.setAttribute("aria-pressed", String(theme === "dark"));
    }
    document.dispatchEvent(new CustomEvent("gistsmith:themechange", { detail: theme }));
  }

  /**
   * Kullanıcının seçimini saklar. Saklanamazsa seçim yalnızca bu sayfada geçerlidir (uyarı yazılır).
   * @param {Theme} theme
   */
  function remember(theme) {
    try {
      window.localStorage.setItem(storageKey, theme);
    } catch (error) {
      console.warn("theme_storage_unavailable", { error: error instanceof Error ? error.message : String(error) });
    }
  }

  apply(storedTheme() ?? systemTheme());

  // Seçim yapılmadıysa sistem teması değişince sayfa da değişir.
  darkQuery.addEventListener("change", () => {
    if (storedTheme() === null) {
      apply(systemTheme());
    }
  });

  document.addEventListener("DOMContentLoaded", () => {
    for (const button of document.querySelectorAll("[data-theme-toggle]")) {
      button.setAttribute("aria-pressed", String(root.dataset["theme"] === "dark"));
      button.addEventListener("click", () => {
        /** @type {Theme} */
        const next = root.dataset["theme"] === "dark" ? "light" : "dark";
        // Renk geçişi yalnızca düğmeyle değişimde ve kısa süre açık (sayfa yüklenirken geçiş olmaz).
        root.classList.add("theme-switching");
        window.setTimeout(() => root.classList.remove("theme-switching"), 400);
        remember(next);
        apply(next);
      });
    }
  });
})();
