// The page a frozen tab shows. Asks the background every second and goes back
// to the original address once the site may run again.
"use strict";

(() => {
  const query = new URLSearchParams(location.search);
  const siteID = query.get("site") || "";
  const original = query.get("u") || "";

  const texts = {
    network: "IP не из разрешённой страны. Сайт не получит ни одного запроса, пока Subzero не подтвердит правильный адрес.",
    manual: "Заморожено вручную в Subzero. Разморозить можно в меню Subzero.",
    stale: "Subzero не отвечает. Пока он не подтвердит разрешённый IP, сайт отрезан от сети.",
    missing: "Нет связи с Subzero. Запустите Subzero — страница вернётся, когда IP будет разрешён.",
    checking: "Subzero проверяет IP. Обычно это занимает пару секунд.",
  };

  const el = (id) => document.getElementById(id);
  el("url").textContent = original;

  function isWeb(url) {
    try {
      const parsed = new URL(url);
      return parsed.protocol === "http:" || parsed.protocol === "https:";
    } catch {
      return false;
    }
  }

  function render(status) {
    if (!status) {
      el("why").textContent = texts.missing;
      return;
    }
    const held = status.mode === "hold";
    const why = status.link === "stale" || status.link === "missing"
      ? status.link
      : status.why === "manual" ? "manual" : held ? "checking" : "network";
    el("banner").textContent = held ? "Hold" : "Frozen!";
    el("banner").classList.toggle("hold", held);
    el("title").textContent = `${status.name || "Сайт"} заморожен`;
    el("why").textContent = texts[why];
    el("detail").textContent = why === "network" && status.detail ? status.detail : "";
    document.title = `❄ ${status.name || "Сайт"} — заморожено`;
  }

  async function tick() {
    let status = null;
    try {
      status = await browser.runtime.sendMessage({ type: "status", site: siteID });
    } catch {
      status = null;
    }
    render(status);
    if (status && !status.frozen && isWeb(original)) {
      location.replace(original);
      return;
    }
    setTimeout(tick, 1000);
  }

  tick();
})();
