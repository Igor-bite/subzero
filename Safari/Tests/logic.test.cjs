// node --test Safari/Tests
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const L = require(path.join(__dirname, "..", "Extension", "logic.js"));

const NOW = 1_800_000_000;
const BASE = "safari-web-extension://ABC/frozen.html";

function command(overrides = {}, sites) {
  return {
    version: 1,
    active: true,
    updatedAt: NOW - 1,
    detail: "IP 1.2.3.4 не разрешён.",
    sites: sites || [
      { id: "claude", name: "Claude", domains: ["claude.ai"], protected: true, mode: "freeze", why: "network", closeAt: 0 },
      { id: "chatgpt", name: "ChatGPT", domains: ["chatgpt.com", "chat.openai.com"], protected: false, mode: "run", closeAt: 0 },
    ],
    ...overrides,
  };
}

const modes = (decision) => Object.fromEntries(decision.sites.map((s) => [s.id, s.mode]));

test("fresh command is followed as is", () => {
  const d = L.decide(command(), NOW);
  assert.equal(d.link, "ok");
  assert.deepEqual(modes(d), { claude: "freeze", chatgpt: "run" });
  assert.equal(d.detail, "IP 1.2.3.4 не разрешён.");
});

test("no command at all holds every known site (fail-closed)", () => {
  for (const state of [null, undefined, {}, { sites: "x" }, "garbage"]) {
    const d = L.decide(state, NOW);
    assert.equal(d.link, "missing");
    assert.deepEqual(modes(d), { claude: "hold", chatgpt: "hold" });
  }
});

test("normal quit releases everything", () => {
  const d = L.decide(command({ active: false }), NOW);
  assert.equal(d.link, "inactive");
  assert.deepEqual(modes(d), { claude: "run", chatgpt: "run" });
});

test("stale command holds protected sites and keeps frozen ones frozen", () => {
  const sites = [
    { id: "claude", name: "Claude", domains: ["claude.ai"], protected: true, mode: "run", closeAt: 0 },
    { id: "chatgpt", name: "ChatGPT", domains: ["chatgpt.com"], protected: false, mode: "run", closeAt: 0 },
    { id: "x", name: "X", domains: ["x.test"], protected: false, mode: "freeze", why: "manual", closeAt: 0 },
  ];
  const d = L.decide(command({ updatedAt: NOW - L.STALE_AFTER - 1 }, sites), NOW);
  assert.equal(d.link, "stale");
  assert.deepEqual(modes(d), { claude: "hold", chatgpt: "run", x: "freeze" });
  assert.equal(d.sites[0].why, "stale");
  assert.equal(d.sites[2].why, "manual");
});

test("hold without network blocking falls back to unloading", () => {
  const site = { mode: "hold" };
  assert.equal(L.effectiveMode(site, true), "hold");
  assert.equal(L.effectiveMode(site, false), "freeze");
  assert.equal(L.effectiveMode({ mode: "run" }, false), "run");
});

test("sites match their domains and subdomains only", () => {
  const sites = L.decide(command(), NOW).sites;
  assert.equal(L.siteForURL("https://claude.ai/chat/1", sites)?.id, "claude");
  assert.equal(L.siteForURL("https://api.claude.ai/x", sites)?.id, "claude");
  assert.equal(L.siteForURL("https://CHAT.OPENAI.COM/", sites)?.id, "chatgpt");
  assert.equal(L.siteForURL("https://notclaude.ai/", sites), null);
  assert.equal(L.siteForURL("https://claude.ai.evil.com/", sites), null);
  assert.equal(L.siteForURL("ftp://claude.ai/", sites), null);
  assert.equal(L.siteForURL("not a url", sites), null);
});

test("frozen page URL round-trips the original address", () => {
  const original = "https://chatgpt.com/c/abc?model=x&q=a%20b#frag";
  const url = L.frozenPageURL(BASE, "chatgpt", original);
  assert.deepEqual(L.parseFrozenPage(url, BASE), { site: "chatgpt", original });
  assert.equal(L.parseFrozenPage("https://chatgpt.com/", BASE), null);
  assert.equal(L.parseFrozenPage(BASE + "x?site=a", BASE), null);
  assert.equal(L.restorable(original), true);
  assert.equal(L.restorable("javascript:alert(1)"), false);
});

test("close orders run once and only while recent", () => {
  const sites = [
    { id: "claude", closeAt: NOW - 5 },
    { id: "chatgpt", closeAt: NOW - L.CLOSE_WINDOW - 1 },
    { id: "never", closeAt: 0 },
  ];
  assert.deepEqual(L.pendingCloses(sites, {}, NOW), ["claude"]);
  assert.deepEqual(L.pendingCloses(sites, { claude: NOW - 5 }, NOW), []);
  assert.deepEqual(L.pendingCloses(sites, { claude: NOW - 50 }, NOW), ["claude"]);
});

test("block rules cover every domain including page loads", () => {
  const sites = L.decide(command(), NOW).sites;
  const rules = L.blockRules(sites);
  const ids = rules.map((r) => r.id);
  assert.equal(new Set(ids).size, ids.length);
  assert.ok(ids.every((id) => id >= L.RULE_BASE));
  const filters = rules.filter((r) => r.condition.urlFilter).map((r) => r.condition.urlFilter);
  assert.deepEqual(filters, ["||claude.ai^", "||chatgpt.com^", "||chat.openai.com^"]);
  assert.ok(rules.find((r) => r.condition.urlFilter).condition.resourceTypes.includes("main_frame"));
  assert.ok(rules.some((r) => r.condition.initiatorDomains));
  assert.ok(!L.blockRules(sites, 1).some((r) => r.condition.initiatorDomains));
  assert.ok(!L.blockRules(sites, 2)[0].condition.resourceTypes.includes("websocket"));
  assert.deepEqual(L.blockRules([]), []);
});

test("rules must stay scoped to a domain", () => {
  const sites = L.decide(command(), NOW).sites;
  assert.ok(L.rulesAreScoped(L.blockRules(sites)));
  assert.ok(L.rulesAreScoped([]));
  // What a rule looks like if Safari drops an unknown key: it would block everything.
  assert.ok(!L.rulesAreScoped([{ id: 1001, condition: { resourceTypes: ["script"] } }]));
  assert.ok(!L.rulesAreScoped([{ id: 1001, condition: { urlFilter: "*" } }]));
  assert.ok(!L.rulesAreScoped([{ id: 1001, condition: { initiatorDomains: [] } }]));
});

test("tab counts split live and frozen pages", () => {
  const sites = L.decide(command(), NOW).sites;
  const counts = L.countTabs([
    "https://claude.ai/a",
    L.frozenPageURL(BASE, "claude", "https://claude.ai/b"),
    L.frozenPageURL(BASE, "chatgpt", "https://chatgpt.com/"),
    "https://example.com/",
  ], sites, BASE);
  assert.deepEqual(counts, { claude: { open: 1, frozen: 1 }, chatgpt: { open: 0, frozen: 1 } });
});

test("catalog matches the manifest permissions", () => {
  const manifest = require(path.join(__dirname, "..", "Extension", "manifest.json"));
  for (const site of L.CATALOG) {
    for (const domain of site.domains) {
      for (const pattern of [`*://${domain}/*`, `*://*.${domain}/*`]) {
        assert.ok(manifest.permissions.includes(pattern), `permissions miss ${pattern}`);
        assert.ok(manifest.content_scripts[0].matches.includes(pattern), `content script misses ${pattern}`);
      }
    }
  }
});
