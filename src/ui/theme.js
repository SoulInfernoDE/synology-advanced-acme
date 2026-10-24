// Color scheme of the web interface, applied before the page is drawn.
//
// Preference (per browser, setting "Appearance"): "light", "dark" or "auto"
// (follows the light or dark mode of the operating system). DSM 7 has no dark
// theme, so inside a DSM window the default is light; outside DSM it is auto.
(function () {
  "use strict";

  const KEY = "aacme.theme";
  const media = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;

  function defaultPref() {
    return window.parent !== window ? "light" : "auto";
  }

  function get() {
    try {
      const v = localStorage.getItem(KEY);
      if (v === "light" || v === "dark" || v === "auto") return v;
    } catch (e) { /* storage unavailable */ }
    return defaultPref();
  }

  function apply() {
    const pref = get();
    const dark = pref === "dark" || (pref === "auto" && media !== null && media.matches);
    document.documentElement.setAttribute("data-theme", dark ? "dark" : "light");
  }

  function set(pref) {
    try { localStorage.setItem(KEY, pref); } catch (e) { /* ignore */ }
    apply();
  }

  if (media) {
    if (media.addEventListener) media.addEventListener("change", apply);
    else if (media.addListener) media.addListener(apply);
  }
  apply();

  window.aacmeTheme = { get: get, set: set };
})();
