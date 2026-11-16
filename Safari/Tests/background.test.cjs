// Runs background.js against a fake `browser` API: the whole loop without Safari.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const DIR = path.join(__dirname, "..", "Extension");
const BASE = "safari-web-extension://TEST/frozen.html";

function fakeBrowser({ dnrFailLevels = 0, noDNR = false, dropsInitiator = false } = {}) {
  const fake = {
    state: null,            // what the native handler returns (object or null)
    nativeFails: false,
    reports: [],
    tabs: [],               // { id, url }
    rules: [],
    stored: {},
    listeners: { nav: [], updated: [], removed: [], message: [], alarm: [] },
    dnrCalls: 0,
  };
  let nextTab = 1;
  fake.openTab = (url) => { const tab = { id: nextTab++, url }; fake.tabs.push(tab); return tab; };

  const dnr = noDNR ? undefined : {
    async getDynamicRules() { return fake.rules.slice(); },
    async updateDynamicRules({ removeRuleIds, addRules }) {
      fake.dnrCalls += 1;
      const level = addRules.some((r) => r.condition.initiatorDomains) ? 0
        : addRules.some((r) => r.condition.resourceTypes.includes("websocket")) ? 1 : 2;
      if (addRules.length > 0 && level < dnrFailLevels) throw new Error(`level ${level} unsupported`);
      const stored = addRules.map((r) => {
        if (!dropsInitiator || !r.condition.initiatorDomains) return r;
        const { initiatorDomains, ...rest } = r.condition;
        return { ...r, condition: rest };
      });
      fake.rules = fake.rules.filter((r) => !removeRuleIds.includes(r.id)).concat(stored);
    },
  };

  fake.browser = {
    runtime: {
      getURL: (p) => `safari-web-extension://TEST/${p}`,
      getManifest: () => ({ version: "9.9.9" }),
      async sendNativeMessage(_app, message) {
        if (message.report) fake.reports.push(JSON.parse(message.report));
        if (fake.nativeFails) throw new Error("no handler");
        return fake.state ? { state: JSON.stringify(fake.state) } : {};
      },
      onMessage: { addListener: (f) => fake.listeners.message.push(f) },
    },
    tabs: {
      async query() { return fake.tabs.map((t) => ({ ...t })); },
      async update(id, { url }) {
        const tab = fake.tabs.find((t) => t.id === id);
        if (tab) tab.url = url;
        return tab;
      },
      async remove(ids) { fake.tabs = fake.tabs.filter((t) => !ids.includes(t.id)); },
      onUpdated: { addListener: (f) => fake.listeners.updated.push(f) },
      onRemoved: { addListener: (f) => fake.listeners.removed.push(f) },
    },
    webNavigation: { onBeforeNavigate: { addListener: (f) => fake.listeners.nav.push(f) } },
    storage: {
      local: {
        async get(key) { return { [key]: fake.stored[key] }; },
        async set(obj) { Object.assign(fake.stored, obj); },
      },
    },
    permissions: { async contains() { return true; } },
    declarativeNetRequest: dnr,
    browserAction: {
      setBadgeText: async () => {}, setBadgeBackgroundColor: async () => {}, setTitle: async () => {},
    },
    alarms: { create() {}, onAlarm: { addListener: (f) => fake.listeners.alarm.push(f) } },
  };

  // Timers: run the loop by hand, not by the clock.
  const context = vm.createContext({
    browser: fake.browser, console: { warn() {}, error() {}, log() {} },
    URL, URLSearchParams, setTimeout: () => 0, clearTimeout: () => {}, Date, Promise, JSON,
  });
  for (const file of ["logic.js", "background.js"]) {
    vm.runInContext(fs.readFileSync(path.join(DIR, file), "utf8"), context, { filename: file });
  }
  fake.cycle = () => vm.runInContext("cycle()", context);
  fake.send = (message, sender = {}) => fake.listeners.message[0](message, sender);
  return fake;
}

function command(claudeMode, { active = true, age = 0, closeAt = 0, why = "network" } = {}) {
  const now = Date.now() / 1000;
  return {
    version: 1, active, updatedAt: now - age, detail: "IP не разрешён",
    sites: [
      { id: "claude", name: "Claude", domains: ["claude.ai"], protected: true, mode: claudeMode, why: claudeMode === "run" ? null : why, closeAt },
      { id: "chatgpt", name: "ChatGPT", domains: ["chatgpt.com", "chat.openai.com"], protected: false, mode: "run", closeAt: 0 },
    ],
  };
}

const settle = () => new Promise((r) => setImmediate(r));
const isFrozenPage = (url) => url.startsWith(BASE);

test("freeze unloads live tabs and blocks the network; run releases", async () => {
  const fake = fakeBrowser();
  await settle();                      // initial cycle on load
  const chat = fake.openTab("https://claude.ai/chat/42");
  const other = fake.openTab("https://example.com/");
  const gpt = fake.openTab("https://chatgpt.com/");

  fake.state = command("freeze");
  await fake.cycle();
  await settle();
  assert.ok(isFrozenPage(chat.url), chat.url);
  assert.equal(new URL(chat.url).searchParams.get("u"), "https://claude.ai/chat/42");
  assert.equal(other.url, "https://example.com/");
  assert.equal(gpt.url, "https://chatgpt.com/");
  assert.ok(fake.rules.some((r) => r.condition.urlFilter === "||claude.ai^"));
  assert.ok(!fake.rules.some((r) => r.condition.urlFilter === "||chatgpt.com^"));

  // The frozen page asks; it may not go back while the rules are on.
  let status = await fake.send({ type: "status", site: "claude" });
  assert.equal(status.frozen, true);
  assert.equal(status.mode, "freeze");
  assert.equal(status.detail, "IP не разрешён");

  fake.state = command("run");
  await fake.cycle();
  assert.equal(fake.rules.length, 0);
  status = await fake.send({ type: "status", site: "claude" });
  assert.equal(status.frozen, false);
  // The background never restores by itself: frozen.js does (it owns the URL).
  assert.ok(isFrozenPage(chat.url));
});

test("hold cuts the network but leaves tabs alone", async () => {
  const fake = fakeBrowser();
  await settle();
  const chat = fake.openTab("https://claude.ai/chat/1");
  fake.state = command("hold");
  await fake.cycle();
  await settle();
  assert.equal(chat.url, "https://claude.ai/chat/1");
  assert.ok(fake.rules.length > 0);
});

test("navigation to a held or frozen site lands on the frozen page", async () => {
  const fake = fakeBrowser();
  await settle();
  fake.state = command("hold");
  await fake.cycle();
  const tab = fake.openTab("about:blank");
  fake.listeners.nav[0]({ frameId: 0, tabId: tab.id, url: "https://claude.ai/new" });
  await settle();
  assert.ok(isFrozenPage(tab.url));

  const tab2 = fake.openTab("about:blank");
  fake.listeners.nav[0]({ frameId: 0, tabId: tab2.id, url: "https://chatgpt.com/" });
  await settle();
  assert.equal(tab2.url, "about:blank");
});

test("no answer from Subzero holds every known site (fail-closed)", async () => {
  const fake = fakeBrowser();
  fake.nativeFails = true;
  await settle();
  const chat = fake.openTab("https://chatgpt.com/c/1");
  await fake.cycle();
  await settle();
  assert.equal(chat.url, "https://chatgpt.com/c/1");     // held, not unloaded
  assert.ok(fake.rules.some((r) => r.condition.urlFilter === "||chatgpt.com^"));
  assert.ok(fake.rules.some((r) => r.condition.urlFilter === "||claude.ai^"));
  const status = await fake.send({ type: "status", site: "chatgpt" });
  assert.equal(status.link, "missing");
});

test("stale heartbeat holds; normal quit releases", async () => {
  const fake = fakeBrowser();
  await settle();
  fake.state = command("run", { age: 60 });
  await fake.cycle();
  assert.ok(fake.rules.some((r) => r.condition.urlFilter === "||claude.ai^"));

  fake.state = command("hold", { active: false });
  await fake.cycle();
  assert.equal(fake.rules.length, 0);
});

test("without network blocking, hold unloads tabs instead", async () => {
  const fake = fakeBrowser({ noDNR: true });
  await settle();
  const chat = fake.openTab("https://claude.ai/");
  fake.state = command("hold");
  await fake.cycle();
  await settle();
  assert.ok(isFrozenPage(chat.url));
  await fake.cycle();
  assert.equal(fake.reports.at(-1)?.blocksNetwork, false);
});

test("rules fall back when Safari rejects a condition", async () => {
  const fake = fakeBrowser({ dnrFailLevels: 2 });
  await settle();
  fake.state = command("freeze");
  await fake.cycle();
  assert.ok(fake.rules.length > 0);
  assert.ok(!fake.rules.some((r) => r.condition.initiatorDomains));
  assert.ok(!fake.rules[0].condition.resourceTypes.includes("websocket"));
});

test("a condition Safari silently drops never leaves a block-everything rule", async () => {
  const fake = fakeBrowser({ dropsInitiator: true });
  await settle();
  fake.state = command("freeze");
  await fake.cycle();
  assert.ok(fake.rules.length > 0);
  assert.ok(fake.rules.every((r) => r.condition.urlFilter), JSON.stringify(fake.rules));
});

test("close order closes live and frozen tabs once", async () => {
  const fake = fakeBrowser();
  await settle();
  fake.state = command("freeze");
  const a = fake.openTab("https://claude.ai/a");
  await fake.cycle();
  await settle();
  const b = fake.openTab("https://claude.ai/b");
  const keep = fake.openTab("https://chatgpt.com/");
  fake.state = command("freeze", { closeAt: Date.now() / 1000 - 1 });
  await fake.cycle();
  assert.deepEqual(fake.tabs.map((t) => t.id), [keep.id]);
  assert.ok(a && b);

  // Same order again: nothing more to close.
  const c = fake.openTab("https://claude.ai/c");
  await fake.cycle();
  await settle();
  assert.ok(fake.tabs.some((t) => t.id === c.id));
  assert.ok(isFrozenPage(c.url));
});

test("report counts tabs per site", async () => {
  const fake = fakeBrowser();
  await settle();
  fake.openTab("https://claude.ai/a");
  fake.openTab("https://claude.ai/b");
  fake.state = command("run");
  await fake.cycle();
  await fake.cycle();   // the report of a cycle travels with the next exchange
  const report = fake.reports.at(-1);
  assert.equal(report.extensionVersion, "9.9.9");
  assert.equal(report.blocksNetwork, true);
  assert.deepEqual(report.sites.find((s) => s.id === "claude"), { id: "claude", open: 2, frozen: 0, access: true });
});

test("content script hello stops a page of a frozen site", async () => {
  const fake = fakeBrowser();
  await settle();
  fake.state = command("freeze");
  const tab = fake.openTab("https://claude.ai/x");
  const reply = await fake.send({ type: "hello" }, { tab: { id: tab.id, url: tab.url } });
  assert.equal(reply.stop, true);
  await settle();
  assert.ok(isFrozenPage(tab.url));
});
