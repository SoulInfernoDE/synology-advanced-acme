/* Advanced ACME web interface. Plain JavaScript, no external dependencies,
 * so it works on a NAS without internet access to CDNs. */
(function () {
  "use strict";

  // ---------------------------------------------------------------------------
  // Providers
  // ---------------------------------------------------------------------------

  const PROVIDERS = {
    ionos: {
      server: "https://acme.ionos.com/directory",
      eab: "required",
      email: "none",
      keylength: "2048",
      dns: "dns_ionos"
    },
    letsencrypt: {
      server: "https://acme-v02.api.letsencrypt.org/directory",
      eab: "none",
      email: "optional",
      keylength: "ec-256",
      dns: "dns_ionos"
    },
    zerossl: {
      server: "https://acme.zerossl.com/v2/DV90",
      eab: "auto",
      email: "required",
      keylength: "ec-256",
      dns: "dns_ionos"
    },
    custom: {
      server: "",
      eab: "optional",
      email: "optional",
      keylength: "2048",
      dns: "dns_ionos"
    }
  };

  const KEY_TYPES = ["ec-256", "ec-384", "2048", "3072", "4096"];

  // ---------------------------------------------------------------------------
  // i18n: English is the base and fallback catalog.
  // ---------------------------------------------------------------------------

  const I18N = { lang: "en", base: {}, cat: {} };

  // Available catalogs (BCP 47 code -> language name in that language).
  const LANGS = {
    en: "English",
    de: "Deutsch",
    fr: "Français",
    it: "Italiano",
    es: "Español",
    nl: "Nederlands",
    pl: "Polski",
    "pt-BR": "Português (Brasil)",
    ru: "Русский",
    ja: "日本語",
    ko: "한국어",
    "zh-CN": "简体中文",
    "zh-TW": "繁體中文",
    sv: "Svenska",
    da: "Dansk",
    nb: "Norsk bokmål",
    cs: "Čeština",
    tr: "Türkçe",
    hu: "Magyar",
    th: "ไทย"
  };

  // DSM language codes -> catalog. Unknown codes use English.
  const DSM_LANGS = {
    enu: "en", ger: "de", fre: "fr", ita: "it", spn: "es", nld: "nl", plk: "pl",
    ptb: "pt-BR", ptg: "pt-BR", rus: "ru", jpn: "ja", krn: "ko", chs: "zh-CN", cht: "zh-TW",
    sve: "sv", dan: "da", nor: "nb", csy: "cs", trk: "tr", hun: "hu", tha: "th"
  };

  // Browser language (e.g. "fr-CA", "zh-Hant-HK") -> catalog.
  function browserLang(tag) {
    const t = (tag || "en").toLowerCase();
    if (t.startsWith("zh")) return /hant|-tw|-hk|-mo/.test(t) ? "zh-TW" : "zh-CN";
    if (t.startsWith("pt")) return "pt-BR";
    if (/^(no|nb|nn)\b/.test(t)) return "nb";
    const base = t.slice(0, 2);
    return LANGS[base] ? base : "en";
  }

  function detectLang() {
    const q = new URLSearchParams(location.search).get("lang");
    if (q && LANGS[q]) return q;
    try {
      const saved = localStorage.getItem("aacme.lang");
      if (saved && LANGS[saved]) return saved;
    } catch (e) { /* storage unavailable */ }
    try {
      const dsm = window.parent && window.parent.SYNO && window.parent.SYNO.SDS &&
        window.parent.SYNO.SDS.Session && window.parent.SYNO.SDS.Session.lang;
      if (dsm && dsm !== "def") return DSM_LANGS[dsm] || "en";
    } catch (e) { /* not inside DSM */ }
    return browserLang(navigator.language);
  }

  async function loadI18n() {
    I18N.lang = detectLang();
    I18N.base = await fetch("i18n/en.json", { cache: "no-store" }).then((r) => r.json());
    I18N.cat = I18N.base;
    if (I18N.lang !== "en") {
      try {
        I18N.cat = await fetch("i18n/" + I18N.lang + ".json", { cache: "no-store" }).then((r) => r.json());
      } catch (e) {
        I18N.cat = I18N.base;
      }
    }
    document.documentElement.lang = I18N.lang;
  }

  function t(key, vars) {
    let s = I18N.cat[key];
    if (s === undefined) s = I18N.base[key];
    if (s === undefined) s = key;
    if (vars) {
      s = s.replace(/\{(\w+)\}/g, (m, k) => (vars[k] !== undefined ? String(vars[k]) : m));
    }
    return s;
  }

  function fmtDate(epoch) {
    if (!epoch) return "–";
    return new Intl.DateTimeFormat(I18N.lang, { dateStyle: "medium", timeStyle: "short" })
      .format(new Date(epoch * 1000));
  }

  function fmtDay(epoch) {
    if (!epoch) return "–";
    return new Intl.DateTimeFormat(I18N.lang, { dateStyle: "long" }).format(new Date(epoch * 1000));
  }

  // ---------------------------------------------------------------------------
  // DOM helpers (no innerHTML with data, everything goes through textContent)
  // ---------------------------------------------------------------------------

  function el(tag, attrs, ...children) {
    const node = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (v === undefined || v === null || v === false) continue;
        if (k === "class") node.className = v;
        else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
        else if (k === "text") node.textContent = v;
        else if (v === true) node.setAttribute(k, "");
        else node.setAttribute(k, v);
      }
    }
    for (const c of children.flat()) {
      if (c === undefined || c === null || c === false) continue;
      node.append(c instanceof Node ? c : document.createTextNode(String(c)));
    }
    return node;
  }

  // Append to `node`; arrays are flattened, null/false skipped.
  function add(node, ...kids) {
    node.append(...kids.flat(Infinity).filter((k) => k !== null && k !== undefined && k !== false));
  }

  // Replace the children of `node`; arrays are flattened, null/false skipped.
  function fill(node, ...kids) {
    node.replaceChildren(...kids.flat(Infinity).filter((k) => k !== null && k !== undefined && k !== false));
  }

  // Text with {link} style placeholders replaced by anchor elements.
  function richText(key, links) {
    const parts = t(key).split(/(\{\w+\})/);
    return parts.map((p) => {
      const m = p.match(/^\{(\w+)\}$/);
      if (m && links[m[1]]) {
        const l = links[m[1]];
        return el("a", { href: l.href, target: "_blank", rel: "noopener noreferrer" }, l.text);
      }
      return p;
    });
  }

  function button(label, opts) {
    opts = opts || {};
    return el("button", {
      type: "button",
      class: "btn " + (opts.kind || "secondary") + (opts.small ? " small" : ""),
      onclick: opts.onclick,
      disabled: opts.disabled
    }, label);
  }

  function field(label, input, help) {
    const id = "f" + Math.random().toString(36).slice(2, 9);
    input.id = id;
    return el("div", { class: "field" },
      el("label", { for: id }, label),
      input,
      help ? el("div", { class: "help" }, help) : null);
  }

  function input(attrs) {
    return el("input", Object.assign({ type: "text", autocomplete: "off", spellcheck: "false" }, attrs));
  }

  function notice(kind, ...content) {
    return el("div", { class: "notice " + kind }, ...content);
  }

  let toastTimer = null;
  function toast(msg, kind) {
    const box = document.getElementById("toast");
    box.textContent = msg;
    box.className = "toast " + (kind || "");
    box.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { box.hidden = true; }, 4500);
  }

  // ---------------------------------------------------------------------------
  // API
  // ---------------------------------------------------------------------------

  function synoToken() {
    try {
      return window.parent.SYNO.SDS.Session.SynoToken || "";
    } catch (e) {
      return "";
    }
  }

  async function api(action, params) {
    const body = new URLSearchParams(Object.assign({ action: action }, params || {}));
    const headers = { "X-AACME": "1", "Content-Type": "application/x-www-form-urlencoded" };
    const token = synoToken();
    if (token) headers["X-SYNO-TOKEN"] = token;
    let res;
    try {
      res = await fetch("api.cgi", { method: "POST", headers: headers, body: body, credentials: "same-origin" });
    } catch (e) {
      return { ok: false, error: "network" };
    }
    try {
      return await res.json();
    } catch (e) {
      return { ok: false, error: "bad_response" };
    }
  }

  function errText(code) {
    if (!code) return t("err.unknown");
    const key = "err." + code;
    const s = t(key);
    return s === key ? t("err.unknown_code", { code: code }) : s;
  }

  // Map acme.sh / hook log output to a friendly explanation.
  const LOG_HINTS = [
    [/externalAccountRequired|eab-kid|External Account Binding/i, "hint.eab"],
    [/You didn't specify an IONOS api prefix/i, "hint.ionos_key"],
    [/Cannot find this domain in your IONOS account/i, "hint.ionos_domain"],
    [/No available certificate found for the requested domain/i, "hint.ionos_no_cert"],
    [/Enter OTP code|2FA-OTP|SYNO_DEVICE_ID \(may be expired/i, "hint.dsm_otp"],
    [/no such account or incorrect password|non-existent account/i, "hint.dsm_password"],
    [/not administrator/i, "hint.dsm_admin"],
    [/No DSM account configured/i, "hint.dsm_missing"],
    [/stopped retrying after reaching the retry limit/i, "hint.ca_processing"],
    [/rateLimited|too many/i, "hint.rate_limit"],
    [/Invalid status|Verify error|Incorrect TXT record|NXDOMAIN/i, "hint.dns_verify"],
    [/caa|CAA record/i, "hint.caa"],
    [/Could not get nonce|Can not init api|Couldn't resolve host|timed out|timeout/i, "hint.network"],
    [/unauthorized|forbidden|rejectedIdentifier/i, "hint.ca_rejected"],
    [/@@FAIL interrupted/, "hint.interrupted"]
  ];

  function hintsFor(log) {
    const out = [];
    for (const [re, key] of LOG_HINTS) {
      if (re.test(log) && !out.includes(key)) out.push(key);
    }
    // A specific reason makes the generic "provider rejected" hint redundant.
    return out.length > 1 ? out.filter((k) => k !== "hint.ca_rejected") : out;
  }

  // Poll a background job and render its progress into `box`.
  function trackJob(jobId, box, opts) {
    opts = opts || {};
    const steps = opts.steps || [];
    const stepList = el("ol", { class: "steps-progress" },
      steps.map((s) => el("li", { "data-step": s }, el("span", { class: "dot" }), t("job.step." + s))));
    const status = el("div", { class: "job-status running" }, el("span", { class: "spinner" }), t("job.running"));
    const pre = el("pre", { class: "log" });
    const details = el("details", { class: "log-details", open: opts.openLog ? true : null },
      el("summary", null, t("job.show_log")), pre);
    const hintBox = el("div", { class: "hints" });
    fill(box, status, steps.length ? stepList : null, hintBox, details);

    return new Promise((resolve) => {
      let stopped = false;
      async function poll() {
        if (stopped) return;
        const r = await api("job", { id: jobId });
        if (!r.ok) {
          status.className = "job-status failed";
          status.textContent = errText(r.error);
          resolve({ ok: false, log: "" });
          return;
        }
        const log = r.log || "";
        const visible = log.split("\n").filter((l) => !l.startsWith("@@")).join("\n");
        const atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;
        pre.textContent = visible;
        if (atBottom) pre.scrollTop = pre.scrollHeight;
        const markers = log.split("\n").filter((l) => l.startsWith("@@"));
        let current = null;
        const failed = new Set();
        const seen = [];
        for (const m of markers) {
          const [kind, name] = m.slice(2).split(" ");
          if (kind === "STEP") { current = name; seen.push(name); }
          if (kind === "FAIL") failed.add(name);
        }
        for (const li of stepList.children) {
          const s = li.getAttribute("data-step");
          li.className = failed.has(s) ? "failed" : (s === current && r.state !== "done") ? "active" :
            seen.includes(s) ? "done" : "";
        }
        if (r.state === "waiting") {
          fill(status, el("span", { class: "spinner" }), t("job.waiting"));
        } else if (r.state === "running" && /Handed over to the DSM task/.test(visible)) {
          fill(status, el("span", { class: "spinner" }), t("job.waiting_task"));
        }
        if (r.state === "done") {
          stopped = true;
          const ok = r.rc === 0;
          if (ok) {
            for (const li of stepList.children) li.className = "done";
            status.className = "job-status ok";
            status.textContent = opts.okText || t("job.ok");
            if (markers.includes("@@INFO deploy_queued")) fill(hintBox, notice("info", t("hint.deploy_queued")));
          } else {
            status.className = "job-status failed";
            status.textContent = opts.failText || t("job.failed");
            details.open = true;
            const hints = hintsFor(log);
            fill(hintBox, ...hints.map((h) => notice("warn", t(h))));
            if (!hints.length) fill(hintBox, notice("warn", t("hint.generic")));
          }
          resolve({ ok: ok, log: log });
          return;
        }
        setTimeout(poll, 1500);
      }
      poll();
    });
  }

  // ---------------------------------------------------------------------------
  // App state and navigation
  // ---------------------------------------------------------------------------

  const state = { status: null, certs: [], accounts: [], dnsapi: null, tab: "certs" };

  const TABS = ["certs", "new", "settings", "expert", "help"];

  function renderTabs() {
    const nav = document.getElementById("tabs");
    fill(nav, ...TABS.map((tab) => el("button", {
      type: "button",
      role: "tab",
      class: "tab" + (state.tab === tab ? " active" : ""),
      "aria-selected": state.tab === tab ? "true" : "false",
      onclick: () => go(tab)
    }, t("tab." + tab))));
  }

  function go(tab) {
    state.tab = tab;
    try { history.replaceState(null, "", "#" + tab); } catch (e) { /* ignore */ }
    renderTabs();
    const view = document.getElementById("view");
    fill(view);
    window.scrollTo(0, 0);
    ({ certs: viewCerts, new: viewWizard, settings: viewSettings, expert: viewExpert, help: viewHelp })[tab](view);
  }

  async function refresh() {
    const [s, c, a] = await Promise.all([api("status"), api("certs"), api("accounts")]);
    if (s.ok) state.status = s;
    if (c.ok) state.certs = c.certs;
    if (a.ok) state.accounts = a.accounts;
    return s;
  }

  async function dnsPlugins() {
    if (!state.dnsapi) {
      try {
        state.dnsapi = await fetch("dnsapi.json", { cache: "no-store" }).then((r) => r.json());
      } catch (e) {
        state.dnsapi = [];
      }
    }
    return state.dnsapi;
  }

  function providerOf(cert) {
    if (cert.provider) return cert.provider;
    for (const [id, p] of Object.entries(PROVIDERS)) {
      if (p.server && cert.server === p.server) return id;
    }
    return "custom";
  }

  // ---------------------------------------------------------------------------
  // View: certificates
  // ---------------------------------------------------------------------------

  async function viewCerts(view) {
    add(view, el("div", { class: "loading" }, el("span", { class: "spinner" }), t("common.loading")));
    const s = await refresh();
    fill(view);
    if (!s.ok) {
      add(view, notice("error", errText(s.error)));
      return;
    }

    add(view, el("div", { class: "page-head" },
      el("h1", null, t("certs.title")),
      button(t("certs.add"), { kind: "primary", onclick: () => go("new") })));

    add(view, serviceBanner());

    if (!state.status.dsm.configured && state.certs.length) {
      add(view, notice("warn", t("certs.dsm_missing"), " ",
        button(t("certs.dsm_missing_action"), { small: true, onclick: () => go("settings") })));
    }

    if (!state.certs.length) {
      add(view, el("section", { class: "empty" },
        el("img", { src: "images/icon_128.png", alt: "", width: 96, height: 96 }),
        el("h2", null, t("certs.empty_title")),
        el("p", null, t("certs.empty_text")),
        el("div", { class: "actions center" },
          button(t("certs.empty_ionos"), { kind: "primary", onclick: () => { wizard.reset("ionos"); go("new"); } }),
          button(t("certs.empty_other"), { onclick: () => { wizard.reset(null); go("new"); } }))));
      return;
    }

    const list = el("div", { class: "cards" });
    for (const cert of state.certs) add(list, certCard(cert));
    add(view, list);
  }

  function serviceBanner() {
    const s = state.status;
    const last = s.last_cron ? fmtDate(s.last_cron) : t("certs.never");
    const ok = s.service_running;
    return el("div", { class: "banner " + (ok ? "ok" : "warn") },
      el("span", { class: "led" }),
      el("span", null, ok ? t("certs.service_on", { last: last }) : t("certs.service_off")),
      s.last_cron_rc && s.last_cron_rc !== 0 ? el("span", { class: "pill bad" }, t("certs.last_run_failed")) : null);
  }

  function certStatus(cert) {
    const now = Date.now() / 1000;
    if (!cert.not_after) return { cls: "bad", text: t("cert.status_missing") };
    const days = Math.floor((cert.not_after - now) / 86400);
    if (days < 0) return { cls: "bad", text: t("cert.status_expired") };
    if (days < 14) return { cls: "warn", text: t("cert.status_soon", { days: days }) };
    return { cls: "ok", text: t("cert.status_valid", { days: days }) };
  }

  function certCard(cert) {
    const st = certStatus(cert);
    const prov = providerOf(cert);
    const names = [cert.domain].concat(cert.alt.filter((d) => d !== cert.domain));
    const result = el("div", { class: "card-job" });

    let deploy;
    if (cert.deploy_status === "fail") deploy = el("span", { class: "pill bad" }, t("cert.deploy_failed"));
    else if (cert.deploy_status === "queued") deploy = el("span", { class: "pill muted" }, t("cert.deploy_queued"));
    else if (cert.deployed || cert.deploy_status === "ok") deploy = el("span", { class: "pill ok" }, t("cert.deploy_ok"));
    else deploy = el("span", { class: "pill muted" }, t("cert.deploy_none"));

    const dsmName = cert.has_meta ? (cert.dsm_desc || t("cert.dsm_default_name")) : cert.domain;

    const actions = el("div", { class: "actions" },
      button(t("cert.renew"), {
        small: true,
        onclick: async () => {
          if (!confirm(t("cert.renew_confirm", { domain: cert.domain }))) return;
          const r = await api("renew", { id: cert.id });
          if (!r.ok) return toast(errText(r.error), "error");
          await runCertJob(r.job, result, ["renew"], cert);
        }
      }),
      button(t("cert.deploy"), {
        small: true,
        onclick: async () => {
          const r = await api("deploy", { id: cert.id });
          if (!r.ok) return toast(errText(r.error), "error");
          await runCertJob(r.job, result, ["deploy"], cert);
        }
      }),
      button(t("cert.target"), { small: true, onclick: () => targetDialog(cert, result) }),
      button(t("cert.remove"), {
        small: true,
        kind: "danger",
        onclick: async () => {
          if (!confirm(t("cert.remove_confirm", { domain: cert.domain }))) return;
          const r = await api("remove", { id: cert.id });
          if (!r.ok) return toast(errText(r.error), "error");
          toast(t("cert.removed"));
          go("certs");
        }
      }));

    return el("article", { class: "card" },
      el("div", { class: "card-head" },
        el("div", null,
          el("h3", null, cert.domain),
          names.length > 1 ? el("div", { class: "sub" }, names.slice(1).join(", ")) : null),
        el("span", { class: "pill " + st.cls }, st.text)),
      el("dl", { class: "facts" },
        el("dt", null, t("cert.provider")), el("dd", null, t("provider." + prov + ".name")),
        el("dt", null, t("cert.valid_until")), el("dd", null, cert.not_after ? fmtDay(cert.not_after) : cert.not_after_str || "–"),
        el("dt", null, t("cert.next_renew")), el("dd", null, fmtDay(cert.next_renew)),
        el("dt", null, t("cert.dsm_target")), el("dd", null, dsmName, " ", deploy),
        el("dt", null, t("cert.validation")), el("dd", null, cert.plugin || "–"),
        el("dt", null, t("cert.keytype")), el("dd", null, keyTypeLabel(cert.keylength))),
      actions,
      result);
  }

  function keyTypeLabel(k) {
    if (!k) return "–";
    return k.startsWith("ec-") ? "ECDSA P-" + k.slice(3) : "RSA " + k;
  }

  async function runCertJob(jobId, box, steps, cert) {
    const res = await trackJob(jobId, box, { steps: steps });
    if (!res.ok && /Enter OTP code|2FA-OTP|SYNO_DEVICE_ID \(may be expired/i.test(res.log)) {
      const otp = input({ inputmode: "numeric", maxlength: "8", placeholder: "123456" });
      add(box, el("div", { class: "inline-form" },
        field(t("dsm.otp"), otp, t("dsm.otp_retry_help")),
        button(t("cert.deploy_with_otp"), {
          kind: "primary",
          onclick: async () => {
            const r = await api("deploy", { id: cert.id, otp: otp.value.trim() });
            if (!r.ok) return toast(errText(r.error), "error");
            runCertJob(r.job, box, ["deploy"], cert);
          }
        })));
    }
    if (res.ok) {
      const r = await api("certs");
      if (r.ok) state.certs = r.certs;
      add(box, button(t("common.refresh"), { small: true, onclick: () => go("certs") }));
    }
  }

  async function targetDialog(cert, box) {
    fill(box, el("div", { class: "loading" }, el("span", { class: "spinner" }), t("dsm.loading_certs")));
    const r = await api("dsm_check");
    if (!r.ok) {
      fill(box, notice("error", errText(r.error)));
      return;
    }
    let chosen = cert.has_meta ? cert.dsm_desc : cert.domain;
    const picker = dsmTargetPicker(r, cert.domain, chosen, (v) => { chosen = v; });
    fill(box, el("div", { class: "subpanel" },
      el("h4", null, t("cert.target_title")),
      picker,
      el("div", { class: "actions" },
        button(t("common.save_and_install"), {
          kind: "primary",
          onclick: async () => {
            const s = await api("set_target", { id: cert.id, dsm_desc: chosen });
            if (!s.ok) return toast(errText(s.error), "error");
            const d = await api("deploy", { id: cert.id });
            if (!d.ok) return toast(errText(d.error), "error");
            runCertJob(d.job, box, ["deploy"], cert);
          }
        }),
        button(t("common.cancel"), { onclick: () => fill(box) }))));
  }

  // List of DSM certificates with "create new" / "replace existing" choice.
  function dsmTargetPicker(dsmResult, domain, current, onChange) {
    const certs = (dsmResult.dsm && dsmResult.dsm.data && dsmResult.dsm.data.certificates) || [];
    const name = "t" + Math.random().toString(36).slice(2, 8);
    const wrap = el("div", { class: "radio-list" });
    const existingDescs = certs.map((c) => c.desc || "");
    const newDesc = existingDescs.includes(current) ? domain : (current || domain);
    const newInput = input({ value: newDesc, maxlength: "120" });

    function opt(value, title, sub, extra, checked) {
      const radio = el("input", { type: "radio", name: name, value: value, checked: checked });
      radio.addEventListener("change", () => onChange(radio.value === "\u0000new" ? newInput.value : radio.value));
      return el("label", { class: "radio-card" }, radio,
        el("div", null, el("strong", null, title), sub ? el("div", { class: "sub" }, sub) : null, extra));
    }

    const isNew = !existingDescs.includes(current);
    const newOpt = opt("\u0000new", t("dsm.target_new"), t("dsm.target_new_help"), newInput, isNew);
    newInput.addEventListener("input", () => {
      newOpt.querySelector("input").checked = true;
      onChange(newInput.value);
    });
    if (isNew) onChange(newInput.value);
    add(wrap, newOpt);

    for (const c of certs) {
      const desc = c.desc || "";
      const subject = (c.subject && c.subject.common_name) || "";
      const services = (c.services || []).map((s) => s.display_name || s.service || "").filter(Boolean);
      const lines = [];
      if (subject) lines.push(t("dsm.cert_for", { name: subject }));
      if (c.valid_till) lines.push(t("dsm.cert_until", { date: c.valid_till }));
      const extra = el("div", null,
        c.is_default ? el("span", { class: "pill ok" }, t("dsm.default_cert")) : null,
        services.length ? el("div", { class: "sub" }, t("dsm.used_by", { services: services.join(", ") })) : null,
        c.renewable ? el("div", { class: "sub warn-text" }, t("dsm.renewable_warning")) : null);
      add(wrap, opt(desc, t("dsm.target_replace", { name: desc || t("cert.dsm_default_name") }),
        lines.join(" · "), extra, !isNew && desc === current));
    }
    return el("div", null, el("p", { class: "muted" }, t("dsm.target_intro")), wrap);
  }

  // ---------------------------------------------------------------------------
  // View: wizard
  // ---------------------------------------------------------------------------

  const wizard = {
    data: null,
    reset(provider) {
      this.data = {
        step: provider ? 1 : 0,
        provider: provider,
        server: provider ? PROVIDERS[provider].server : "",
        email: "",
        dnsPlugin: "dns_ionos",
        dnsEnv: {},
        ionosZones: null,
        zone: "",
        host: "",
        includeApex: false,
        wildcard: false,
        extra: "",
        keylength: provider ? PROVIDERS[provider].keylength : "2048",
        dsmDesc: "",
        dsmList: null,
        force: false
      };
    }
  };
  wizard.reset(null);

  const WIZ_STEPS = ["provider", "account", "dns", "domains", "dsm", "summary"];

  // Without a DSM account the wizard starts with connecting Advanced ACME to
  // DSM, shown as an extra first step before the provider.
  async function viewWizard(view) {
    const d = wizard.data;
    if (!state.status) await refresh();
    const connecting = !(state.status && state.status.dsm && state.status.dsm.configured);
    add(view, el("div", { class: "page-head" }, el("h1", null, t("wiz.title"))));
    add(view, el("ol", { class: "wizard-steps" }, ["connect"].concat(WIZ_STEPS).map((s, i) => {
      const pos = connecting ? 0 : d.step + 1;
      return el("li", { class: i === pos ? "active" : i < pos ? "done" : "" },
        el("span", { class: "num" }, String(i + 1)), el("span", { class: "label" }, t("wiz.step." + s)));
    })));
    const body = el("section", { class: "panel" });
    add(view, body);
    if (connecting) return wizConnect(body);
    [wizProvider, wizAccount, wizDns, wizDomains, wizDsm, wizSummary][d.step](body);
  }

  // Step 0: connect to DSM (only while no DSM account is set up)
  function wizConnect(body) {
    const intro = el("p", { class: "muted" }, t("wiz.connect.intro"));
    add(body, el("h2", null, t("wiz.connect.title")), intro,
      dsmAccountForm(async () => {
        await refresh();
        wizGo(wizard.data.step);
      }, false, null, [intro]));
  }

  function wizGo(step) {
    wizard.data.step = step;
    go("new");
  }

  function wizNav(back, next, nextLabel, nextDisabled) {
    return el("div", { class: "actions wizard-nav" },
      back !== null ? button(t("common.back"), { onclick: () => wizGo(back) }) : el("span"),
      next ? button(nextLabel || t("common.next"), { kind: "primary", onclick: next, disabled: nextDisabled }) : null);
  }

  // Step 1: provider
  function wizProvider(body) {
    const d = wizard.data;
    add(body, el("h2", null, t("wiz.provider.title")), el("p", { class: "muted" }, t("wiz.provider.intro")));
    const grid = el("div", { class: "choice-grid" });
    for (const id of Object.keys(PROVIDERS)) {
      add(grid, el("button", {
        type: "button",
        class: "choice" + (d.provider === id ? " selected" : ""),
        onclick: () => {
          wizard.reset(id);
          wizGo(1);
        }
      },
      id === "ionos" ? el("span", { class: "pill ok corner" }, t("wiz.provider.recommended_ionos")) : null,
      el("strong", null, t("provider." + id + ".name")),
      el("span", null, t("provider." + id + ".desc"))));
    }
    add(body, grid);
  }

  // acme.sh keys accounts by host (without port) and path of the directory URL.
  function accountExists(server) {
    try {
      const u = new URL(server);
      return state.accounts.includes("https://" + u.hostname + u.pathname.replace(/\/$/, ""));
    } catch (e) {
      return false;
    }
  }

  // Step 2: ACME account (EAB for IONOS)
  function wizAccount(body) {
    const d = wizard.data;
    const p = PROVIDERS[d.provider];
    add(body, el("h2", null, d.provider === "custom" ? t("wiz.account.title_custom") :
      t("wiz.account.title", { provider: t("provider." + d.provider + ".name") })));

    const serverIn = input({ value: d.server, placeholder: "https://acme.example.com/directory" });
    const emailIn = input({ type: "email", value: d.email, placeholder: "name@example.com" });
    const kidIn = input({ placeholder: t("wiz.account.kid_placeholder") });
    const hmacIn = input({ type: "password", placeholder: t("wiz.account.hmac_placeholder") });
    // Instructions and fields; hidden while an existing connection is offered.
    const setup = el("div");

    if (d.provider === "ionos") {
      add(setup, el("ol", { class: "howto" },
        el("li", null, richText("wiz.account.ionos_step1", { link: { href: t("link.ionos_ssl"), text: t("link.ionos_ssl_text") } })),
        el("li", null, t("wiz.account.ionos_step2")),
        el("li", null, t("wiz.account.ionos_step3")),
        el("li", null, t("wiz.account.ionos_step4")),
        el("li", null, richText("wiz.account.ionos_step5", { link: { href: t("link.ionos_certs"), text: t("link.ionos_certs_text") } }))),
      notice("info", t("wiz.account.ionos_note"), " ",
        el("a", { href: t("link.ionos_acme_help"), target: "_blank", rel: "noopener noreferrer" }, t("wiz.account.ionos_help"))));
    } else if (d.provider === "letsencrypt") {
      add(setup, el("p", { class: "muted" }, t("wiz.account.le_intro")));
    } else if (d.provider === "zerossl") {
      add(setup, el("p", { class: "muted" }, t("wiz.account.zerossl_intro")));
    } else {
      add(setup, el("p", { class: "muted" }, t("wiz.account.custom_intro")));
    }

    const form = el("div", { class: "form" });
    if (d.provider === "custom") add(form, field(t("wiz.account.server"), serverIn, t("wiz.account.server_help")));
    if (p.eab === "required" || p.eab === "optional") {
      add(form, field(t("wiz.account.kid"), kidIn), field(t("wiz.account.hmac"), hmacIn,
        p.eab === "required" ? t("wiz.account.hmac_help") : t("wiz.account.eab_optional")));
    }
    if (p.email !== "none") {
      add(form, field(p.email === "required" ? t("wiz.account.email_required") : t("wiz.account.email_optional"), emailIn));
    }
    add(setup, form);

    const jobBox = el("div");
    const known = d.server && accountExists(d.server);
    if (known) add(body, notice("ok", t("wiz.account.already_connected")));
    setup.hidden = known;
    add(body, setup, jobBox);

    async function connect() {
      d.server = (d.provider === "custom" ? serverIn.value.trim() : p.server);
      d.email = emailIn.value.trim();
      if (!/^https:\/\//.test(d.server)) return toast(t("err.invalid_server"), "error");
      if (p.eab === "required" && (!kidIn.value.trim() || !hmacIn.value.trim())) {
        return toast(t("wiz.account.eab_missing"), "error");
      }
      if (p.email === "required" && !d.email) return toast(t("err.invalid_email"), "error");
      const params = { server: d.server, email: d.email };
      if (kidIn.value.trim()) {
        params.eab_kid = kidIn.value.trim();
        params.eab_hmac = hmacIn.value.trim();
      }
      const r = await api("register", params);
      if (!r.ok) return toast(errText(r.error), "error");
      const res = await trackJob(r.job, jobBox, { steps: ["register"], okText: t("wiz.account.connected") });
      if (res.ok) {
        const a = await api("accounts");
        if (a.ok) state.accounts = a.accounts;
        body.querySelector(".wizard-nav").remove();
        add(jobBox, wizNav(0, () => wizGo(2)));
      }
    }

    // Already connected: using the connection is the main action (right).
    // "Connect again" first shows the instructions and fields.
    const nav = el("div", { class: "actions wizard-nav" });
    function renderNav(reconnecting) {
      const useExisting = () => wizGo(2);
      fill(nav, button(t("common.back"), { onclick: () => wizGo(0) }),
        el("div", { class: "actions" },
          !known ? button(t("wiz.account.connect"), { kind: "primary", onclick: connect }) :
            reconnecting ? [button(t("wiz.account.skip"), { onclick: useExisting }),
              button(t("wiz.account.connect"), { kind: "primary", onclick: connect })] :
              [button(t("wiz.account.reconnect"), { onclick: () => { setup.hidden = false; renderNav(true); } }),
                button(t("wiz.account.skip"), { kind: "primary", onclick: useExisting })]));
    }
    renderNav(false);
    add(body, nav);
  }

  // Step 3: DNS validation
  async function wizDns(body) {
    const d = wizard.data;
    add(body, el("h2", null, t("wiz.dns.title")), el("p", { class: "muted" }, t("wiz.dns.intro")));

    const plugins = await dnsPlugins();
    const select = el("select", null,
      el("option", { value: "dns_ionos" }, t("wiz.dns.ionos_option")),
      el("optgroup", { label: t("wiz.dns.other_providers") },
        plugins.filter((p) => p.id !== "dns_ionos").map((p) =>
          el("option", { value: p.id }, p.name + " (" + p.id + ")"))));
    select.value = d.dnsPlugin;
    select.addEventListener("change", () => {
      d.dnsPlugin = select.value;
      d.dnsEnv = {};
      d.ionosZones = null;
      wizGo(2);
    });
    add(body, el("div", { class: "form" }, field(t("wiz.dns.provider"), select)));

    const area = el("div");
    add(body, area);

    if (d.dnsPlugin === "dns_ionos") {
      await ionosDnsForm(area);
    } else {
      await genericDnsForm(area, plugins.find((p) => p.id === d.dnsPlugin));
    }
  }

  async function ionosDnsForm(area) {
    const d = wizard.data;
    const saved = await api("dns_saved", { keys: "IONOS_PREFIX,IONOS_SECRET" });
    const hasSaved = saved.ok && saved.saved.IONOS_PREFIX && saved.saved.IONOS_SECRET;

    // A stored key is used as it is; entering another one stays possible.
    const keyForm = el("div", null,
      el("ol", { class: "howto" },
        el("li", null, richText("wiz.dns.ionos_step1", { link: { href: t("link.ionos_dev"), text: t("link.ionos_dev_text") } })),
        el("li", null, t("wiz.dns.ionos_step2")),
        el("li", null, t("wiz.dns.ionos_step3"))));
    const prefixIn = input({ placeholder: t("wiz.dns.prefix_placeholder"), value: d.dnsEnv.IONOS_PREFIX || "" });
    const secretIn = input({ type: "password", placeholder: t("wiz.dns.secret_placeholder"), value: d.dnsEnv.IONOS_SECRET || "" });
    add(keyForm, el("div", { class: "form" },
      field(t("wiz.dns.prefix"), prefixIn),
      field(t("wiz.dns.secret"), secretIn, hasSaved ? t("wiz.dns.saved_hint") : t("wiz.dns.secret_help"))));
    const useSaved = hasSaved && !d.dnsEnv.IONOS_PREFIX;
    keyForm.hidden = useSaved;
    if (useSaved) {
      add(area, notice("ok", t("wiz.dns.key_saved"), " ",
        button(t("wiz.dns.other_key"), {
          small: true,
          onclick: (ev) => { keyForm.hidden = false; ev.target.hidden = true; prefixIn.focus(); }
        })));
    }
    add(area, keyForm);

    const result = el("div");
    add(area, result);

    function showZones(zones) {
      d.ionosZones = zones;
      fill(result, zones.length
        ? notice("ok", t("wiz.dns.zones_found", { count: zones.length }), el("div", { class: "zone-list" },
          zones.map((z) => el("span", { class: "pill muted" }, z))))
        : notice("warn", t("wiz.dns.no_zones")));
    }

    async function check() {
      const params = {};
      // A combined "prefix.secret" key pasted into the prefix field is split.
      let prefix = prefixIn.value.trim();
      let secret = secretIn.value.trim();
      if (!secret && prefix.includes(".")) {
        secret = prefix.slice(prefix.indexOf(".") + 1);
        prefix = prefix.slice(0, prefix.indexOf("."));
        prefixIn.value = prefix;
        secretIn.value = secret;
      }
      if (prefix || secret) {
        params.prefix = prefix;
        params.secret = secret;
      }
      fill(result, el("div", { class: "loading" }, el("span", { class: "spinner" }), t("wiz.dns.checking")));
      const r = await api("ionos_zones", params);
      if (!r.ok) {
        fill(result, notice("error", errText(r.error)));
        return false;
      }
      d.dnsEnv = prefix ? { IONOS_PREFIX: prefix, IONOS_SECRET: secret } : {};
      showZones(r.zones);
      return r.zones.length > 0;
    }

    if (d.ionosZones) showZones(d.ionosZones);
    else if (useSaved) check();

    add(area, el("div", { class: "actions wizard-nav" },
      button(t("common.back"), { onclick: () => wizGo(1) }),
      el("div", { class: "actions" },
        button(t("wiz.dns.check"), { onclick: check }),
        button(t("common.next"), {
          kind: "primary",
          onclick: async () => {
            if (!d.ionosZones || (prefixIn.value.trim() && !d.dnsEnv.IONOS_PREFIX)) {
              if (!(await check())) return;
            }
            wizGo(3);
          }
        }))));
  }

  async function genericDnsForm(area, plugin) {
    const d = wizard.data;
    if (!plugin) return;
    const keys = plugin.options.concat(plugin.optionsAlt).map((o) => o.key);
    const saved = keys.length ? await api("dns_saved", { keys: keys.join(",") }) : { ok: true, saved: {} };
    const docs = plugin.docs ? "https://" + plugin.docs.replace(/^https?:\/\//, "") : "";
    add(area, el("p", { class: "muted" }, t("wiz.dns.generic_intro"), " ",
      docs ? el("a", { href: docs, target: "_blank", rel: "noopener noreferrer" }, t("wiz.dns.plugin_docs")) : null));

    const inputs = {};
    function group(title, opts) {
      if (!opts.length) return null;
      return el("fieldset", { class: "form" }, el("legend", null, title), opts.map((o) => {
        const secret = /key|secret|token|pass/i.test(o.key);
        const inp = input({ type: secret ? "password" : "text", value: d.dnsEnv[o.key] || "" });
        inputs[o.key] = inp;
        const isSaved = saved.ok && saved.saved[o.key];
        return field(o.key, inp, [o.desc, isSaved ? t("wiz.dns.saved_hint") : ""].filter(Boolean).join(" · "));
      }));
    }
    add(area, group(t("wiz.dns.options"), plugin.options),
      plugin.optionsAlt.length ? group(t("wiz.dns.options_alt"), plugin.optionsAlt) : null);
    if (!keys.length) add(area, notice("info", t("wiz.dns.no_options")));

    add(area, wizNav(1, () => {
      d.dnsEnv = {};
      for (const [k, inp] of Object.entries(inputs)) {
        if (inp.value.trim()) d.dnsEnv[k] = inp.value.trim();
      }
      wizGo(3);
    }));
  }

  function wizardDomains() {
    const d = wizard.data;
    const out = [];
    if (d.zone) {
      const host = d.host.trim().replace(/\.$/, "");
      // The first name becomes the main name of the certificate. Wildcard
      // certificates are named after *.domain (IONOS issues only a certificate
      // that matches the one in the contract), so the wildcard goes first.
      if (d.wildcard) out.push("*." + d.zone);
      if (host) out.push(host + "." + d.zone);
      if (d.includeApex || !host) out.push(d.zone);
    }
    for (const line of d.extra.split(/[\s,]+/)) {
      const v = line.trim().toLowerCase();
      if (v) out.push(v);
    }
    return Array.from(new Set(out));
  }

  // Step 4: domains
  function wizDomains(body) {
    const d = wizard.data;
    add(body, el("h2", null, t("wiz.domains.title")), el("p", { class: "muted" }, t("wiz.domains.intro")));
    const preview = el("div", { class: "preview" });
    const form = el("div", { class: "form" });

    function update() {
      const names = wizardDomains();
      fill(preview, el("strong", null, t("wiz.domains.preview")), " ",
        names.length ? names.map((n) => el("span", { class: "pill muted" }, n)) : t("wiz.domains.none"));
    }

    const zones = d.dnsPlugin === "dns_ionos" ? (d.ionosZones || []) : [];
    if (zones.length) {
      if (!d.zone || !zones.includes(d.zone)) d.zone = zones[0];
      const zoneSel = el("select", null, zones.map((z) => el("option", { value: z }, z)));
      zoneSel.value = d.zone;
      zoneSel.addEventListener("change", () => { d.zone = zoneSel.value; update(); });
      const hostIn = input({ value: d.host, placeholder: "nas" });
      hostIn.addEventListener("input", () => { d.host = hostIn.value.trim().toLowerCase(); update(); });
      const apex = el("input", { type: "checkbox", checked: d.includeApex });
      apex.addEventListener("change", () => { d.includeApex = apex.checked; update(); });
      const wild = el("input", { type: "checkbox", checked: d.wildcard });
      wild.addEventListener("change", () => { d.wildcard = wild.checked; update(); });
      add(form, 
        field(t("wiz.domains.zone"), zoneSel),
        field(t("wiz.domains.host"), hostIn, t("wiz.domains.host_help")),
        el("label", { class: "check" }, apex, t("wiz.domains.apex")),
        el("label", { class: "check" }, wild, t("wiz.domains.wildcard")));
      if (d.provider === "ionos") add(form, notice("info", t("wiz.domains.wildcard_ionos")));
    } else {
      d.zone = "";
    }
    const extraIn = el("textarea", { rows: zones.length ? 2 : 4, placeholder: "nas.example.com\nwww.example.com" });
    extraIn.value = d.extra;
    extraIn.addEventListener("input", () => { d.extra = extraIn.value; update(); });
    add(form, field(zones.length ? t("wiz.domains.extra") : t("wiz.domains.list"), extraIn, t("wiz.domains.list_help")));

    const keySel = el("select", null, KEY_TYPES.map((k) => el("option", { value: k }, keyTypeLabel(k))));
    keySel.value = d.keylength;
    keySel.addEventListener("change", () => { d.keylength = keySel.value; });
    const force = el("input", { type: "checkbox", checked: d.force });
    force.addEventListener("change", () => { d.force = force.checked; });
    const adv = el("details", { class: "advanced" }, el("summary", null, t("common.advanced")),
      field(t("wiz.domains.keytype"), keySel, t("wiz.domains.keytype_help")),
      el("label", { class: "check" }, force, t("wiz.domains.force")));

    add(body, form, preview, adv);
    update();
    add(body, wizNav(2, () => {
      const names = wizardDomains();
      const bad = names.filter((n) => !/^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$/i.test(n));
      if (!names.length) return toast(t("wiz.domains.none"), "error");
      if (bad.length) return toast(t("wiz.domains.invalid", { names: bad.join(", ") }), "error");
      if (!d.dsmDesc) d.dsmDesc = names[0].replace(/^\*\./, "wildcard.");
      wizGo(4);
    }));
  }

  // DSM account form, used by the wizard and the settings page. By default
  // Advanced ACME creates its own account "advanced-acme" with a one-time
  // sign-in; an existing account can be entered instead. For NAS that enforce
  // 2-step verification for all administrators, a DSM task (no account) is the
  // third way. When DSM refuses the account for that reason, the form switches
  // to a focused view with only what the task needs; "aside" lists elements
  // around the form that are hidden in that view.
  function dsmAccountForm(onSuccess, compact, startMode, aside) {
    const userIn = input({ autocomplete: "username" });
    const passIn = input({ type: "password", autocomplete: "current-password" });
    const otpIn = input({ inputmode: "numeric", maxlength: "8", placeholder: t("dsm.otp_placeholder") });
    const result = el("div");
    const name = "m" + Math.random().toString(36).slice(2, 8);
    let mode = startMode || "auto";

    const intro = el("p", { class: "muted" });
    const dedicated = el("details", { class: "advanced" }, el("summary", null, t("dsm.dedicated_title")),
      el("ol", { class: "howto" },
        el("li", null, t("dsm.dedicated_1")),
        el("li", null, t("dsm.dedicated_2")),
        el("li", null, t("dsm.dedicated_3")),
        el("li", null, t("dsm.dedicated_4"))));
    const userLabel = el("span");
    const otpHelp = el("span");
    const submit = button("", { kind: "primary", onclick: () => run() });
    const radios = {};

    function opt(value, title, sub) {
      const radio = el("input", { type: "radio", name: name, value: value, checked: value === mode });
      radio.addEventListener("change", () => { mode = radio.value; render(); });
      radios[value] = radio;
      return el("label", { class: "radio-card" }, radio,
        el("div", null, el("strong", null, title), el("div", { class: "sub" }, sub)));
    }
    const taskOpt = opt("task", t("dsm.mode_task"), t("dsm.mode_task_help"));
    const choice = el("div", { class: "radio-list" },
      opt("auto", t("dsm.mode_auto"), t("dsm.mode_auto_help")),
      opt("existing", t("dsm.mode_existing"), t("dsm.mode_existing_help")),
      taskOpt);
    let taskShown = mode === "task";
    const moreLink = el("button", { type: "button", class: "link-button",
      onclick: () => { taskShown = true; render(); } }, t("dsm.more_options"));

    // Focused view for the DSM task.
    const focusInfo = el("div");
    const how = el("details", { class: "advanced" }, el("summary", null, t("dsm.task_how")),
      el("p", null, t("dsm.task_intro", { name: "Advanced ACME" })),
      el("p", null, t("dsm.task_exempt")));
    const backLink = el("button", { type: "button", class: "link-button", onclick: () => unfocus() },
      t("dsm.back_to_choice"));
    let focused = false;

    function focusTask(refused) {
      focused = true;
      taskShown = true;
      mode = "task";
      radios.task.checked = true;
      fill(focusInfo, notice("info", refused ? t("dsm.task_focus_otp") : t("dsm.task_focus")));
      fill(result);
      render();
      (userIn.value ? passIn : userIn).focus();
    }

    function unfocus() {
      focused = false;
      taskShown = true;
      fill(focusInfo);
      render();
    }

    function render() {
      for (const e of [choice, intro].concat(aside || [])) e.hidden = focused;
      taskOpt.hidden = !taskShown;
      moreLink.hidden = focused || taskShown;
      if (compact) intro.hidden = true;
      how.hidden = backLink.hidden = !focused;
      intro.textContent = mode === "auto" ? t("dsm.auto_intro", { name: "advanced-acme" }) :
        mode === "task" ? t("dsm.task_intro", { name: "Advanced ACME" }) : t("dsm.intro");
      dedicated.hidden = mode !== "existing";
      userLabel.textContent = mode === "existing" ? t("dsm.user") : t("dsm.admin_user");
      otpHelp.textContent = mode === "existing" ? t("dsm.otp_help") : t("dsm.otp_once_help");
      submit.textContent = mode === "auto" ? t("dsm.create") : mode === "task" ? t("dsm.task_create") : t("dsm.check");
    }

    async function run() {
      if (!userIn.value.trim() || !passIn.value) return toast(t("dsm.missing"), "error");
      const action = { auto: "dsm_create_service", existing: "dsm_check", task: "dsm_create_task" }[mode];
      const busy = mode === "auto" ? t("dsm.creating") : mode === "task" ? t("dsm.task_creating") : t("dsm.checking");
      fill(result, el("div", { class: "loading" }, el("span", { class: "spinner" }), busy));
      const r = await api(action, { user: userIn.value.trim(), pass: passIn.value, otp: otpIn.value.trim() });
      passIn.value = "";
      otpIn.value = "";
      // DSM enforces 2-step verification for every administrator: go straight
      // to the DSM task instead of showing an error.
      if (!r.ok && r.error === "dsm_svc_otp") return focusTask(true);
      if (!r.ok) {
        // The DSM error code helps to tell DSM policies apart.
        fill(result, notice("error", errText(r.error), r.code ? " (DSM " + r.code + ")" : null));
        return;
      }
      if (mode !== "existing") userIn.value = "";
      fill(result, notice("ok", mode === "auto" ? t("dsm.created", { user: r.user }) :
        mode === "task" ? t("dsm.task_ok", { name: "Advanced ACME" }) : t("dsm.ok", { user: r.user })));
      onSuccess(r);
    }

    const wrap = el("div", null,
      choice,
      moreLink,
      focusInfo,
      intro,
      dedicated,
      el("div", { class: "form" },
        field(userLabel, userIn),
        field(t("dsm.password"), passIn),
        field(t("dsm.otp"), otpIn, otpHelp)),
      result,
      el("div", { class: "actions" }, submit),
      backLink,
      how);
    if (startMode === "task") focusTask(false);
    else render();
    return wrap;
  }

  // Short line about how certificates get into DSM (account or DSM task).
  function dsmConnectedNotice(r) {
    return r.mode === "task" ? t("dsm.task_ok", { name: "Advanced ACME" }) : t("dsm.ok", { user: r.user });
  }

  // Step 5: DSM installation
  async function wizDsm(body) {
    const d = wizard.data;
    add(body, el("h2", null, t("wiz.dsm.title")));
    const area = el("div");
    add(body, area);

    function showPicker(r) {
      d.dsmList = r;
      fill(area,
        notice("ok", dsmConnectedNotice(r), " ",
          button(t("dsm.change_account"), { small: true, onclick: () => withAccountForm() })),
        dsmTargetPicker(r, wizardDomains()[0].replace(/^\*\./, "wildcard."), d.dsmDesc, (v) => { d.dsmDesc = v; }),
        wizNav(3, () => wizGo(5)));
    }

    const withAccountForm = (...before) => fill(area, ...before, dsmAccountForm(async (r) => {
      await refresh();
      showPicker(r);
    }), wizNav(3, null));

    if (state.status && state.status.dsm.configured) {
      add(area, el("div", { class: "loading" }, el("span", { class: "spinner" }), t("dsm.loading_certs")));
      const r = await api("dsm_check");
      if (r.ok) return showPicker(r);
      withAccountForm(notice("error", errText(r.error)));
    } else {
      withAccountForm();
    }
  }

  // Step 6: summary and run
  function wizSummary(body) {
    const d = wizard.data;
    const names = wizardDomains();
    add(body, el("h2", null, t("wiz.summary.title")),
      el("dl", { class: "facts wide" },
        el("dt", null, t("cert.provider")), el("dd", null, t("provider." + d.provider + ".name")),
        el("dt", null, t("wiz.summary.server")), el("dd", null, d.server),
        el("dt", null, t("wiz.summary.domains")), el("dd", null, names.join(", ")),
        el("dt", null, t("cert.validation")), el("dd", null, d.dnsPlugin),
        el("dt", null, t("cert.keytype")), el("dd", null, keyTypeLabel(d.keylength)),
        el("dt", null, t("cert.dsm_target")), el("dd", null, d.dsmDesc || t("cert.dsm_default_name"))),
      notice("info", t("wiz.summary.note")));

    const jobBox = el("div");
    const runBtn = button(t("wiz.summary.run"), {
      kind: "primary",
      onclick: async () => {
        runBtn.disabled = true;
        const params = {
          server: d.server,
          plugin: d.dnsPlugin,
          keylength: d.keylength,
          provider: d.provider,
          dsm_desc: d.dsmDesc,
          force: d.force ? "1" : "0",
          domains: names.join("\n")
        };
        for (const [k, v] of Object.entries(d.dnsEnv)) params["env_" + k] = v;
        const r = await api("issue", params);
        if (!r.ok) {
          runBtn.disabled = false;
          return toast(errText(r.error), "error");
        }
        const res = await trackJob(r.job, jobBox, { steps: ["issue", "deploy"], okText: t("wiz.summary.success") });
        if (res.ok) {
          nav.remove();
          add(jobBox, notice("ok", t("wiz.summary.success_next")),
            el("div", { class: "actions" }, button(t("wiz.summary.to_overview"), {
              kind: "primary", onclick: () => { wizard.reset(null); go("certs"); }
            })));
        } else {
          runBtn.disabled = false;
          runBtn.textContent = t("wiz.summary.retry");
        }
      }
    });
    const nav = el("div", { class: "actions wizard-nav" },
      button(t("common.back"), { onclick: () => wizGo(4) }), runBtn);
    add(body, jobBox, nav);
  }

  // ---------------------------------------------------------------------------
  // View: settings
  // ---------------------------------------------------------------------------

  async function viewSettings(view) {
    await refresh();
    const s = state.status;
    add(view, el("div", { class: "page-head" }, el("h1", null, t("settings.title"))));

    // DSM account or DSM task, with the history of these steps
    const dsmBox = el("section", { class: "panel" }, el("h2", null, t("wiz.dsm.title")));
    const showForm = (startMode) => fill(dsmBox, el("h2", null, t("wiz.dsm.title")),
      dsmAccountForm(async () => { await refresh(); renderDsm(); }, true, startMode), activityBox());

    function renderDsm() {
      const st = state.status.dsm;
      fill(dsmBox, el("h2", null, t("wiz.dsm.title")));
      if (st.mode === "task") {
        const task = st.task;
        const stale = !task.last_run || Date.now() / 1000 - task.last_run > 600;
        add(dsmBox, notice("ok", t("settings.dsm_task_active", { name: task.name })),
          stale ? notice("warn", t("settings.dsm_task_not_running", { name: task.name }), " ",
            button(t("settings.dsm_task_setup_again"), { small: true, onclick: () => showForm("task") })) :
            el("p", { class: "muted" }, t("settings.dsm_task_last_run", { time: fmtDate(task.last_run) })),
          task.version && task.version < task.current_version ? notice("info", t("settings.dsm_task_outdated")) : null,
          el("div", { class: "actions" },
            task.version && task.version < task.current_version ?
              button(t("settings.dsm_task_update"), { kind: "primary", onclick: () => showForm("task") }) : null,
            button(t("settings.dsm_change_method"), { onclick: () => showForm() }),
            button(t("settings.dsm_task_remove"), {
              kind: "danger",
              onclick: async () => {
                if (!confirm(t("settings.dsm_task_remove_confirm", { name: task.name }))) return;
                await api("dsm_task_remove");
                toast(t("settings.dsm_task_removing"));
                await refresh();
                renderDsm();
              }
            })));
      } else if (st.configured) {
        add(dsmBox, notice("ok", t("settings.dsm_configured", { user: st.user })),
          st.managed ? el("p", { class: "muted" }, t("settings.dsm_managed")) : null,
          st.two_factor_token ? el("p", { class: "muted" }, t("settings.dsm_2fa_token")) : null,
          el("div", { class: "actions" },
            button(t("dsm.check"), {
              onclick: async () => {
                const r = await api("dsm_check");
                toast(r.ok ? t("dsm.ok", { user: r.user }) : errText(r.error), r.ok ? "" : "error");
              }
            }),
            button(t("dsm.change_account"), { onclick: () => showForm() }),
            button(t("settings.dsm_forget"), {
              kind: "danger",
              onclick: async () => {
                const q = st.managed ? t("settings.dsm_forget_managed_confirm", { user: st.user })
                  : t("settings.dsm_forget_confirm");
                if (!confirm(q)) return;
                const r = await api("dsm_forget");
                if (r.ok && r.managed) {
                  toast(r.removed ? t("settings.dsm_removed", { user: r.user })
                    : t("settings.dsm_remove_manual", { user: r.user }), r.removed ? "" : "error");
                }
                await refresh();
                renderDsm();
              }
            })));
      } else {
        add(dsmBox, notice("warn", t("settings.dsm_missing")),
          st.task && st.task.removing ? el("p", { class: "muted" }, t("settings.dsm_task_removing")) : null,
          dsmAccountForm(async () => { await refresh(); renderDsm(); }));
      }
      add(dsmBox, activityBox());
    }

    // History: collapsed, loaded when opened.
    function activityBox() {
      const list = el("ol");
      const box = el("details", { class: "activity" }, el("summary", null, t("settings.activity")), list);
      box.addEventListener("toggle", async () => {
        if (!box.open) return;
        const r = await api("activity");
        const events = (r.ok && r.events) || [];
        fill(list, events.length ? events.slice().reverse().map((ev) =>
          el("li", null, el("time", null, fmtDate(ev.t)), t("activity." + ev.e, ev.a || {}))) :
          el("li", { class: "muted" }, t("settings.activity_empty")));
      });
      return box;
    }
    renderDsm();
    add(view, dsmBox);

    // Renewal
    const days = input({ type: "number", min: "1", max: "120", value: s.settings.renew_before_days });
    const notify = el("input", { type: "checkbox", checked: s.settings.notify });
    add(view, el("section", { class: "panel" },
      el("h2", null, t("settings.renew_title")),
      el("div", { class: "form" },
        field(t("settings.renew_days"), days, t("settings.renew_days_help")),
        el("label", { class: "check" }, notify, t("settings.notify"))),
      el("div", { class: "actions" }, button(t("common.save"), {
        kind: "primary",
        onclick: async () => {
          const a = await api("settings_set", { key: "renew_before_days", value: days.value });
          const b = await api("settings_set", { key: "notify", value: notify.checked ? "1" : "0" });
          toast(a.ok && b.ok ? t("common.saved") : errText(a.error || b.error), a.ok && b.ok ? "" : "error");
        }
      }))));

    // DSM connection
    const scheme = el("select", null,
      el("option", { value: "" }, t("settings.conn_auto")),
      el("option", { value: "http" }, "HTTP"),
      el("option", { value: "https" }, "HTTPS"));
    scheme.value = s.settings.dsm_scheme || "";
    const port = input({ value: s.settings.dsm_port || "", placeholder: "5000 / 5001", inputmode: "numeric" });
    const host = input({ value: s.settings.dsm_host || "", placeholder: "localhost" });
    add(view, el("section", { class: "panel" },
      el("h2", null, t("settings.conn_title")),
      el("p", { class: "muted" }, t("settings.conn_intro")),
      el("details", { class: "advanced" }, el("summary", null, t("common.advanced")),
        el("div", { class: "form" },
          field(t("settings.conn_scheme"), scheme),
          field(t("settings.conn_port"), port),
          field(t("settings.conn_host"), host, t("settings.conn_host_help"))),
        el("div", { class: "actions" }, button(t("common.save"), {
          onclick: async () => {
            const auto = scheme.value === "";
            const res = await Promise.all([
              api("settings_set", { key: "dsm_scheme", value: scheme.value }),
              api("settings_set", { key: "dsm_port", value: auto ? "" : port.value.trim() }),
              api("settings_set", { key: "dsm_host", value: host.value.trim() })
            ]);
            const bad = res.find((r) => !r.ok);
            toast(bad ? errText(bad.error) : t("common.saved"), bad ? "error" : "");
          }
        })))));

    // acme.sh version and updates
    add(view, acmeVersionPanel());

    // Language
    const lang = el("select", null,
      el("option", { value: "auto" }, t("settings.lang_auto")),
      Object.entries(LANGS).map(([code, name]) => el("option", { value: code }, name)));
    try { lang.value = localStorage.getItem("aacme.lang") || "auto"; } catch (e) { lang.value = "auto"; }
    lang.addEventListener("change", async () => {
      try { localStorage.setItem("aacme.lang", lang.value); } catch (e) { /* ignore */ }
      await loadI18n();
      go("settings");
    });
    add(view, el("section", { class: "panel" }, el("h2", null, t("settings.lang_title")),
      el("div", { class: "form" }, field(t("settings.lang"), lang))));

    // Service log
    const logPre = el("pre", { class: "log" });
    add(view, el("section", { class: "panel" },
      el("h2", null, t("settings.service_title")),
      serviceBanner(),
      el("p", { class: "muted" }, t("settings.service_info", { version: s.version, acme: s.acme_version })),
      el("details", {
        class: "log-details",
        ontoggle: async (e) => {
          if (!e.target.open) return;
          const r = await api("service_log");
          logPre.textContent = r.ok ? (r.log || t("settings.log_empty")) : errText(r.error);
        }
      }, el("summary", null, t("settings.service_log")), logPre)));
  }

  function experimentalNotice() {
    const a = state.status.acme;
    return notice("warn", t("acme.experimental", { version: a.active, bundled: a.bundled }));
  }

  // Settings panel: active acme.sh version, update check, update, revert, auto update.
  function acmeVersionPanel() {
    const panel = el("section", { class: "panel" });
    const jobBox = el("div");
    const result = el("div");

    function render() {
      const a = state.status.acme;
      const auto = el("input", { type: "checkbox", checked: state.status.settings.acme_auto_update });
      auto.addEventListener("change", async () => {
        if (auto.checked && !confirm(t("acme.auto_confirm", { bundled: a.bundled }))) {
          auto.checked = false;
          return;
        }
        const r = await api("settings_set", { key: "acme_auto_update", value: auto.checked ? "1" : "0" });
        toast(r.ok ? t("common.saved") : errText(r.error), r.ok ? "" : "error");
        if (r.ok) state.status.settings.acme_auto_update = auto.checked;
      });
      fill(panel,
        el("h2", null, t("acme.title")),
        el("p", { class: "muted" }, t("acme.intro", { bundled: a.bundled })),
        el("dl", { class: "facts" },
          el("dt", null, t("acme.active")),
          el("dd", null, a.updated ? t("acme.active_updated", { version: a.active }) : t("acme.active_bundled", { version: a.active })),
          a.checked ? el("dt", null, t("acme.last_check")) : null,
          a.checked ? el("dd", null, fmtDate(a.checked) + (a.latest ? " · " + t("acme.latest", { version: a.latest }) : "")) : null),
        a.updated ? experimentalNotice() : null,
        el("div", { class: "actions" },
          button(t("acme.check"), { onclick: check }),
          a.updated ? button(t("acme.revert", { bundled: a.bundled }), { kind: "danger", onclick: revert }) : null),
        result,
        el("label", { class: "check spaced" }, auto, t("acme.auto")),
        el("div", { class: "help" }, t("acme.auto_help")),
        jobBox);
    }

    async function check() {
      fill(result, el("div", { class: "loading" }, el("span", { class: "spinner" }), t("acme.checking")));
      const r = await api("acme_check");
      if (!r.ok) return fill(result, notice("error", errText(r.error)));
      if (!r.update_available) return fill(result, notice("ok", t("acme.up_to_date", { version: r.latest })));
      fill(result, notice("info", t("acme.update_available", { version: r.latest }), " ",
        button(t("acme.update_now", { version: r.latest }), { small: true, kind: "primary", onclick: () => update(r.latest) })));
    }

    async function update(version) {
      if (!confirm(t("acme.update_confirm", { version: version, bundled: state.status.acme.bundled }))) return;
      const r = await api("acme_update", { tag: version });
      if (!r.ok) return toast(errText(r.error), "error");
      fill(result);
      const res = await trackJob(r.job, jobBox, { steps: ["acme_update"] });
      if (res.ok) {
        await refresh();
        render();
      }
    }

    async function revert() {
      if (!confirm(t("acme.revert_confirm", { bundled: state.status.acme.bundled }))) return;
      const r = await api("acme_revert");
      if (!r.ok) return toast(errText(r.error), "error");
      toast(t("acme.reverted", { version: r.version }));
      await refresh();
      render();
    }

    render();
    return panel;
  }

  // ---------------------------------------------------------------------------
  // View: expert (acme.sh console)
  // ---------------------------------------------------------------------------

  // Split a command line like a POSIX shell (quotes and backslashes, no expansion).
  function splitArgs(line) {
    const out = [];
    let cur = "";
    let quote = null;
    let has = false;
    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (quote) {
        if (c === quote) quote = null;
        else if (c === "\\" && quote === "\"" && i + 1 < line.length) cur += line[++i];
        else cur += c;
      } else if (c === "'" || c === "\"") {
        quote = c;
        has = true;
      } else if (c === "\\" && i + 1 < line.length) {
        cur += line[++i];
        has = true;
      } else if (/\s/.test(c)) {
        if (has || cur) out.push(cur);
        cur = "";
        has = false;
      } else {
        cur += c;
      }
    }
    if (quote) return null;
    if (has || cur) out.push(cur);
    return out;
  }

  async function viewExpert(view) {
    await refresh();
    const s = state.status;
    add(view, el("div", { class: "page-head" }, el("h1", null, t("expert.title"))));
add(view, notice("info", t("expert.intro")));
    if (s.acme.updated) add(view, experimentalNotice());

    const cmd = input({ class: "mono", placeholder: "--list" });
    const out = el("div");
    async function run(line) {
      let l = (line || cmd.value).trim().replace(/^acme\.sh\s+/, "");
      const args = splitArgs(l);
      if (!args || !args.length) return toast(t("expert.parse_error"), "error");
      const r = await api("expert", { args: args.join("\n") });
      if (!r.ok) return toast(errText(r.error), "error");
      trackJob(r.job, out, { openLog: true });
    }
    cmd.addEventListener("keydown", (e) => { if (e.key === "Enter") run(); });

    add(view, el("section", { class: "panel" },
      el("h2", null, t("expert.console")),
      el("div", { class: "console-line" }, el("span", { class: "mono prompt" }, "acme.sh"), cmd,
        button(t("expert.run"), { kind: "primary", onclick: () => run() })),
      el("div", { class: "actions" },
        ["--list", "--info", "--cron", "--version", "--list --listraw"].map((c) =>
          button(c, { small: true, onclick: () => { cmd.value = c; run(c); } }))),
      el("p", { class: "help" }, t("expert.examples")),
      el("pre", { class: "snippet" },
        "--issue --server https://acme.ionos.com/directory --dns dns_ionos -d nas.example.com --keylength 2048 --days -30\n" +
        "--deploy -d nas.example.com --deploy-hook advanced_acme_dsm\n" +
        "--set-notify --notify-hook mail"),
      out));

    add(view, el("section", { class: "panel" },
      el("h2", null, t("expert.ssh_title")),
      el("p", { class: "muted" }, t("expert.ssh_intro")),
      el("pre", { class: "snippet" },
        "sudo advanced-acme acme --list\n" +
        "sudo advanced-acme acme --renew -d nas.example.com --force\n" +
        "sudo advanced-acme cron\n" +
        "sudo advanced-acme status"),
      el("dl", { class: "facts wide" },
        el("dt", null, t("expert.path_acme")), el("dd", { class: "mono" }, s.paths.acme_home),
        el("dt", null, t("expert.path_config")), el("dd", { class: "mono" }, s.paths.acme_config),
        el("dt", null, t("expert.path_cli")), el("dd", { class: "mono" }, s.paths.cli)),
      el("p", { class: "help" }, t("expert.hook_info"))));

    const jobs = await api("jobs");
    const tbody = el("tbody");
    if (jobs.ok) {
      for (const j of jobs.jobs) {
        const st = j.state === "done" ? (j.rc === 0 ? ["ok", t("job.ok_short")] : ["bad", t("job.failed_short")]) : ["muted", t("job.running_short")];
        const logBox = el("div");
        add(tbody, el("tr", null,
          el("td", null, fmtDate(j.started)),
          el("td", null, t("jobtype." + j.type)),
          el("td", { class: "mono" }, j.label),
          el("td", null, el("span", { class: "pill " + st[0] }, st[1])),
          el("td", null, button(t("expert.view"), {
            small: true,
            onclick: (e) => {
              const row = e.target.closest("tr");
              const next = row.nextElementSibling;
              if (next && next.classList.contains("log-row")) { next.remove(); return; }
              row.after(el("tr", { class: "log-row" }, el("td", { colspan: "5" }, logBox)));
              trackJob(j.id, logBox, { openLog: true });
            }
          }))));
      }
    }
    add(view, el("section", { class: "panel" }, el("h2", null, t("expert.history")),
      el("div", { class: "table-wrap" }, el("table", { class: "table" },
        el("thead", null, el("tr", null,
          el("th", null, t("expert.col_time")), el("th", null, t("expert.col_type")),
          el("th", null, t("expert.col_label")), el("th", null, t("expert.col_state")), el("th"))),
        tbody))));
  }

  // ---------------------------------------------------------------------------
  // View: help
  // ---------------------------------------------------------------------------

  function viewHelp(view) {
    add(view, el("div", { class: "page-head" }, el("h1", null, t("help.title"))));
    const topics = ["how", "ionos180", "updates", "dsm_gui", "security", "dsm_account", "dsm_task", "default", "uninstall", "dns01"];
    add(view, el("section", { class: "panel faq" }, topics.map((k, i) =>
      el("details", { open: i === 0 ? true : null },
        el("summary", null, t("help." + k + ".q")),
        el("p", null, t("help." + k + ".a"))))));
    add(view, el("section", { class: "panel" },
      el("h2", null, t("help.links")),
      el("ul", { class: "links" },
        [["link.ionos_acme_help", "help.link_ionos_acme"], ["link.ionos_dev", "help.link_ionos_dev"],
          ["link.acme_wiki", "help.link_acme"], ["link.acme_dsm", "help.link_acme_dsm"]].map(([href, label]) =>
          el("li", null, el("a", { href: t(href), target: "_blank", rel: "noopener noreferrer" }, t(label)))))));
  }

  // ---------------------------------------------------------------------------
  // Start
  // ---------------------------------------------------------------------------

  async function start() {
    // DSM itself has no dark theme: match it when running inside a DSM window.
    if (window.parent !== window) document.documentElement.setAttribute("data-theme", "light");
    try {
      await loadI18n();
    } catch (e) {
      document.getElementById("view").textContent = "Failed to load language files.";
      return;
    }
    renderTabs();
    const s = await refresh();
    if (!s.ok && (s.error === "not_logged_in" || s.error === "not_admin")) {
      fill(document.getElementById("view"), notice("error", errText(s.error)));
      return;
    }
    // Deep links: #settings, #new, #new/ionos (assistant for a provider), ...
    const [tab, provider] = location.hash.slice(1).split("/");
    if (provider && PROVIDERS[provider]) wizard.reset(provider);
    go(TABS.includes(tab) ? tab : "certs");
  }

  start();
})();
