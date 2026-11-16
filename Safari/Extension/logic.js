// Pure decisions of the Subzero Safari extension: no browser APIs here, so the
// rules can be tested with Node (`node --test Safari/Tests`).
//
// Subzero writes a command (`SafariCommand` in Sources/SubzeroCore/Safari.swift):
//   { version, active, updatedAt, detail?, sites: [{ id, name, domains, protected, mode, why?, closeAt }] }
// mode: "run" (normal), "hold" (network cut, tabs stay), "freeze" (network cut, tabs unloaded).
//
// Fail-closed: without a fresh command from Subzero, protected sites are held.
"use strict";

const SubzeroLogic = (() => {
  /** Sites the extension knows; must match `SafariSite.catalog` and the manifest permissions. */
  const CATALOG = [
    { id: "claude", name: "Claude", domains: ["claude.ai"] },
    { id: "chatgpt", name: "ChatGPT", domains: ["chatgpt.com", "chat.openai.com"] },
  ];

  /** Subzero rewrites the command every 3 s; older than this means it hung or crashed. */
  const STALE_AFTER = 15;
  /** A close order is carried out only this soon after it was given (no surprise closes later). */
  const CLOSE_WINDOW = 60;

  const MODES = new Set(["run", "hold", "freeze"]);

  function validCommand(state) {
    return !!state && typeof state === "object" && Array.isArray(state.sites)
      && typeof state.updatedAt === "number";
  }

  function normalizeSite(site) {
    return {
      id: String(site.id),
      name: String(site.name || site.id),
      domains: Array.isArray(site.domains) ? site.domains.map((d) => String(d).toLowerCase()) : [],
      protected: !!site.protected,
      mode: MODES.has(site.mode) ? site.mode : "hold",
      why: site.why || null,
      closeAt: typeof site.closeAt === "number" ? site.closeAt : 0,
    };
  }

  /**
   * What to do with every site, given the command (or null when Subzero could not
   * be reached) and the time in seconds.
   * Returns { link: "ok" | "inactive" | "stale" | "missing", detail, sites: [...] }.
   */
  function decide(state, now) {
    if (!validCommand(state)) {
      return {
        link: "missing",
        detail: null,
        sites: CATALOG.map((s) => ({ ...s, protected: true, mode: "hold", why: "missing", closeAt: 0 })),
      };
    }
    const sites = state.sites.map(normalizeSite);
    if (state.active === false) {
      return { link: "inactive", detail: null, sites: sites.map((s) => ({ ...s, mode: "run", why: null })) };
    }
    if (now - state.updatedAt > STALE_AFTER) {
      return {
        link: "stale",
        detail: null,
        sites: sites.map((s) => {
          if (s.mode === "freeze") return s;
          if (s.protected || s.mode === "hold") return { ...s, mode: "hold", why: "stale" };
          return s;
        }),
      };
    }
    return { link: "ok", detail: typeof state.detail === "string" ? state.detail : null, sites };
  }

  /** "hold" relies on network blocking; without it the tab has to be unloaded. */
  function effectiveMode(site, blocksNetwork) {
    if (site.mode === "hold" && !blocksNetwork) return "freeze";
    return site.mode;
  }

  function hostOf(url) {
    try {
      const parsed = new URL(url);
      if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
      return parsed.hostname.toLowerCase();
    } catch {
      return null;
    }
  }

  function hostMatches(host, domain) {
    return host === domain || host.endsWith("." + domain);
  }

  /** The site a web URL belongs to, or null. */
  function siteForURL(url, sites) {
    const host = hostOf(url);
    if (!host) return null;
    return sites.find((s) => s.domains.some((d) => hostMatches(host, d))) || null;
  }

  function frozenPageURL(base, siteID, original) {
    return `${base}?site=${encodeURIComponent(siteID)}&u=${encodeURIComponent(original)}`;
  }

  /** { site, original } when `url` is our frozen page, otherwise null. */
  function parseFrozenPage(url, base) {
    if (typeof url !== "string" || !url.startsWith(base)) return null;
    const rest = url.slice(base.length);
    if (rest && rest[0] !== "?" && rest[0] !== "#") return null;
    const query = new URLSearchParams(rest.split("#")[0].replace(/^\?/, ""));
    const site = query.get("site");
    if (!site) return null;
    return { site, original: query.get("u") || "" };
  }

  /** Only web pages may be restored (never javascript:, file:, …). */
  function restorable(url) {
    return hostOf(url) !== null;
  }

  /** Ids of sites whose close order is new (after `handled`) and recent. */
  function pendingCloses(sites, handled, now) {
    return sites
      .filter((s) => s.closeAt > (handled[s.id] || 0) && now - s.closeAt < CLOSE_WINDOW && s.closeAt <= now + 5)
      .map((s) => s.id);
  }

  const RESOURCE_TYPES = [
    "main_frame", "sub_frame", "stylesheet", "script", "image", "font",
    "xmlhttprequest", "ping", "media", "websocket", "other",
  ];
  const BASIC_RESOURCE_TYPES = ["main_frame", "sub_frame", "stylesheet", "script", "image", "font", "xmlhttprequest", "media", "other"];

  /** First id of our dynamic rules; everything from here up belongs to Subzero. */
  const RULE_BASE = 1000;

  /**
   * declarativeNetRequest rules that cut every request to the sites (and, at level 0,
   * every request their pages start). Level 1 and 2 are fallbacks for Safari versions
   * that reject a condition.
   */
  function blockRules(sites, level = 0) {
    const types = level >= 2 ? BASIC_RESOURCE_TYPES : RESOURCE_TYPES;
    const rules = [];
    let id = RULE_BASE;
    for (const site of sites) {
      for (const domain of site.domains) {
        rules.push({
          id: id++,
          priority: 1,
          action: { type: "block" },
          condition: { urlFilter: `||${domain}^`, resourceTypes: types },
        });
        if (level === 0) {
          rules.push({
            id: id++,
            priority: 1,
            action: { type: "block" },
            condition: { initiatorDomains: [domain], resourceTypes: types.filter((t) => t !== "main_frame") },
          });
        }
      }
    }
    return rules;
  }

  /** Every rule of ours is limited to a site; a rule without a domain condition would block the web. */
  function rulesAreScoped(rules) {
    return rules.every((r) => {
      const c = r.condition || {};
      const hasFilter = typeof c.urlFilter === "string" && /[a-z0-9]\.[a-z]/i.test(c.urlFilter);
      const hasInitiator = Array.isArray(c.initiatorDomains) && c.initiatorDomains.length > 0;
      return hasFilter || hasInitiator;
    });
  }

  /** Tab counts per site for the report: live pages and frozen pages. */
  function countTabs(urls, sites, base) {
    const counts = Object.fromEntries(sites.map((s) => [s.id, { open: 0, frozen: 0 }]));
    for (const url of urls) {
      const frozen = parseFrozenPage(url, base);
      if (frozen) {
        if (counts[frozen.site]) counts[frozen.site].frozen += 1;
        continue;
      }
      const site = siteForURL(url, sites);
      if (site) counts[site.id].open += 1;
    }
    return counts;
  }

  return {
    CATALOG, STALE_AFTER, CLOSE_WINDOW, RULE_BASE,
    decide, effectiveMode, siteForURL, frozenPageURL, parseFrozenPage, restorable,
    pendingCloses, blockRules, rulesAreScoped, countTabs,
  };
})();

if (typeof module !== "undefined") module.exports = SubzeroLogic;
