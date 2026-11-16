// Runs at document_start on protected sites. Wakes the background and stops the
// page at once if the site is held or frozen (the background then unloads the tab).
// Network blocking already cut the request in normal operation; this is a backstop.
"use strict";

(() => {
  try {
    browser.runtime.sendMessage({ type: "hello" }).then((reply) => {
      if (reply && reply.stop) window.stop();
    }).catch(() => {});
  } catch {
    // The extension is reloading; nothing to do.
  }
})();
