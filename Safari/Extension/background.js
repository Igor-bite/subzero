// Subzero for Safari: enforces the orders Subzero writes for protected sites.
//
// Every second: send the latest report to Subzero and read its command through
// native messaging (the handler in Safari/Handler), decide (logic.js), then
// 1) cut the network to held/frozen sites with declarativeNetRequest,
// 2) unload live tabs of frozen sites to frozen.html (it restores itself later),
// 3) close tabs when Subzero orders it.
// The page is persistent so the rules follow Subzero even with no site tab open.
"use strict";

const L = SubzeroLogic;
const POLL_MS = 1000;
const REPORT_EVERY_MS = 5000;
const FROZEN_BASE = browser.runtime.getURL("frozen.html");
const VERSION = browser.runtime.getManifest().version;

let decision = L.decide(null, Date.now() / 1000);
let blocksNetwork = typeof browser.declarativeNetRequest?.updateDynamicRules === "function";
/** Sites whose blocking rules are installed right now. */
let blockedNow = new Set();
let appliedRulesKey = null;
let report = null;
let lastReportKey = null;
let lastReportSent = 0;
let running = false;
let timer = null;
/** tabId -> ms of the last unload we started, to avoid double navigation. */
const unloading = new Map();

function now() {
  return Date.now() / 1000;
}

function modeOf(site) {
  return L.effectiveMode(site, blocksNetwork);
}

function siteByID(id) {
  return decision.sites.find((s) => s.id === id) || L.CATALOG.find((s) => s.id === id) || null;
}

// MARK: - Native link

async function exchange() {
  const message = { op: "sync" };
  const key = report ? JSON.stringify({ ...report, at: 0 }) : null;
  if (report && (key !== lastReportKey || Date.now() - lastReportSent >= REPORT_EVERY_MS)) {
    message.report = JSON.stringify(report);
    lastReportKey = key;
    lastReportSent = Date.now();
  }
  try {
    const reply = await browser.runtime.sendNativeMessage("com.klyuzhevigor.subzero", message);
    if (reply && typeof reply.state === "string") return JSON.parse(reply.state);
  } catch (error) {
    console.warn("Subzero: native link failed", error);
  }
  return null;
}

// MARK: - Network

async function applyRules(sites) {
  const key = JSON.stringify(sites.map((s) => [s.id, s.domains]));
  if (key === appliedRulesKey) return;
  const dnr = browser.declarativeNetRequest;
  if (!dnr?.updateDynamicRules) {
    blocksNetwork = false;
    blockedNow = new Set();
    appliedRulesKey = key;
    return;
  }
  const ours = async () => (await dnr.getDynamicRules().catch(() => [])).filter((r) => r.id >= L.RULE_BASE);
  // Some Safari versions reject a condition; fall back to simpler rules.
  for (const level of [0, 1, 2]) {
    try {
      const removeRuleIds = (await ours()).map((r) => r.id);
      await dnr.updateDynamicRules({ removeRuleIds, addRules: L.blockRules(sites, level) });
      // A condition Safari silently dropped would leave a rule that blocks every site.
      if (!L.rulesAreScoped(await ours())) {
        console.warn(`Subzero: rules level ${level} lost their domain condition`);
        continue;
      }
      blocksNetwork = true;
      blockedNow = new Set(sites.map((s) => s.id));
      appliedRulesKey = key;
      return;
    } catch (error) {
      console.warn(`Subzero: rules level ${level} rejected`, error);
    }
  }
  // Nothing safe could be installed: remove ours, tabs get unloaded instead.
  try {
    await dnr.updateDynamicRules({ removeRuleIds: (await ours()).map((r) => r.id), addRules: [] });
  } catch (error) {
    console.warn("Subzero: cannot remove rules", error);
  }
  blocksNetwork = false;
  blockedNow = new Set();
  appliedRulesKey = key;
}

// MARK: - Tabs

function unloadTab(tabId, site, url) {
  const started = unloading.get(tabId);
  if (started && Date.now() - started < 3000) return;
  unloading.set(tabId, Date.now());
  browser.tabs.update(tabId, { url: L.frozenPageURL(FROZEN_BASE, site.id, url) }).catch((error) => {
    console.warn("Subzero: cannot unload tab", error);
  });
}

/** A page of a held or frozen site is opening: show the frozen page instead. */
function interceptNavigation(tabId, url) {
  if (tabId < 0 || !url) return;
  const site = L.siteForURL(url, decision.sites);
  if (site && modeOf(site) !== "run") unloadTab(tabId, site, url);
}

async function closedHandled() {
  const stored = await browser.storage.local.get("closed").catch(() => ({}));
  return stored.closed || {};
}

async function enforceTabs() {
  const tabs = await browser.tabs.query({});
  const handled = await closedHandled();
  const toClose = new Set(L.pendingCloses(decision.sites, handled, now()));
  const closeTabs = [];

  for (const tab of tabs) {
    const url = tab.url || tab.pendingUrl;
    if (!url) continue;
    const frozen = L.parseFrozenPage(url, FROZEN_BASE);
    const site = frozen ? siteByID(frozen.site) : L.siteForURL(url, decision.sites);
    if (!site) continue;
    if (toClose.has(site.id)) {
      closeTabs.push(tab.id);
    } else if (!frozen && modeOf(site) === "freeze") {
      unloadTab(tab.id, site, url);
    }
  }

  if (toClose.size > 0) {
    if (closeTabs.length > 0) await browser.tabs.remove(closeTabs).catch(() => {});
    for (const id of toClose) handled[id] = siteByID(id)?.closeAt || now();
    await browser.storage.local.set({ closed: handled }).catch(() => {});
  }

  for (const [tabId, started] of unloading) {
    if (Date.now() - started > 10000) unloading.delete(tabId);
  }
  return tabs;
}

async function hasAccess(site) {
  try {
    const origins = site.domains.flatMap((d) => [`*://${d}/*`, `*://*.${d}/*`]);
    return await browser.permissions.contains({ origins });
  } catch {
    return true;
  }
}

async function buildReport(tabs) {
  const urls = tabs.map((t) => t.url || t.pendingUrl).filter(Boolean);
  const counts = L.countTabs(urls, decision.sites, FROZEN_BASE);
  const sites = [];
  for (const site of decision.sites) {
    sites.push({ id: site.id, ...counts[site.id], access: await hasAccess(site) });
  }
  return { version: 1, at: now(), extensionVersion: VERSION, blocksNetwork, sites };
}

/** Ignores a failed promise; some Safari APIs return nothing. */
function quiet(result) {
  if (result && typeof result.catch === "function") result.catch(() => {});
}

let lastBadge = null;

function updateBadge() {
  const modes = decision.sites.map(modeOf);
  const text = modes.includes("freeze") ? "❄" : modes.includes("hold") ? "…" : "";
  const titles = { ok: "Subzero", inactive: "Subzero выключен", stale: "Subzero не отвечает", missing: "Нет связи с Subzero" };
  const title = titles[decision.link] || "Subzero";
  if (lastBadge === text + title) return;
  lastBadge = text + title;
  const action = browser.browserAction || browser.action;
  if (!action) return;
  try {
    quiet(action.setBadgeText({ text }));
    if (action.setBadgeBackgroundColor) quiet(action.setBadgeBackgroundColor({ color: "#3fb4ff" }));
    quiet(action.setTitle({ title }));
  } catch (error) {
    console.warn("Subzero: badge", error);
  }
}

// MARK: - Loop

async function cycle() {
  if (running) return;
  running = true;
  try {
    const state = await exchange();
    decision = L.decide(state, now());
    await applyRules(decision.sites.filter((s) => modeOf(s) !== "run"));
    const tabs = await enforceTabs();
    report = await buildReport(tabs);
    updateBadge();
  } catch (error) {
    console.error("Subzero: cycle failed", error);
  } finally {
    running = false;
  }
}

function schedule() {
  clearTimeout(timer);
  timer = setTimeout(async () => {
    await cycle();
    schedule();
  }, POLL_MS);
}

// MARK: - Events

browser.webNavigation?.onBeforeNavigate.addListener((details) => {
  if (details.frameId === 0) interceptNavigation(details.tabId, details.url);
});

browser.tabs.onUpdated.addListener((tabId, change) => {
  if (change.url) interceptNavigation(tabId, change.url);
});

browser.tabs.onRemoved.addListener((tabId) => unloading.delete(tabId));

browser.runtime.onMessage.addListener((message, sender) => {
  if (!message || typeof message !== "object") return undefined;

  if (message.type === "status") {
    // Asked by frozen.html every second.
    const site = siteByID(message.site);
    const mode = site?.mode ? modeOf(site) : "run";
    return Promise.resolve({
      name: site?.name || message.site,
      mode,
      // The page may go back only once the network to the site is open again.
      frozen: mode !== "run" || blockedNow.has(message.site),
      why: site?.why || null,
      link: decision.link,
      detail: decision.detail,
    });
  }

  if (message.type === "hello") {
    // A protected page started loading (content.js). Make sure we are awake and current.
    return cycle().then(() => {
      const url = sender?.tab?.url;
      const site = url ? L.siteForURL(url, decision.sites) : null;
      const stop = !!site && modeOf(site) !== "run";
      if (stop && sender.tab.id >= 0) unloadTab(sender.tab.id, site, url);
      return { stop };
    });
  }
  return undefined;
});

// In case Safari ever unloads the page: wake up once a minute.
browser.alarms?.create("subzero-heartbeat", { periodInMinutes: 1 });
browser.alarms?.onAlarm.addListener(() => {
  cycle().then(schedule);
});

cycle().then(schedule);
