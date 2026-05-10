(function () {
  const display = document.getElementById("root-display");
  const sessionDisplay = document.getElementById("session-display");
  const chooseBtn = document.getElementById("root-choose");
  const resetBtn = document.getElementById("root-reset");
  const refreshBtn = document.getElementById("root-refresh");
  const treeEl = document.getElementById("tree");
  const status = document.getElementById("tree-status");

  const tree = window.cmuxProSidebarTree.create({ rootEl: treeEl, statusEl: status });
  const ws = window.cmuxProSidebarWorkspace;
  let sessionRoot = "";
  let currentRoot = "";

  function applyRoot(path, opts) {
    const next = path || "";
    currentRoot = next;
    if (display) {
      display.textContent = currentRoot || "(no root)";
      display.title = currentRoot;
    }
    tree.setRoot(currentRoot);
    if (!opts || opts.broadcast !== false) {
      document.dispatchEvent(new CustomEvent("cmux:fileRoot:changed", {
        detail: { path: currentRoot },
      }));
    }
  }

  function applySessionRoot(path) {
    sessionRoot = path || "";
    if (sessionDisplay) {
      sessionDisplay.textContent = sessionRoot || "(no session dir)";
      sessionDisplay.title = sessionRoot;
    }
  }

  async function reload() {
    try {
      const reply = await window.cmuxProSidebar.getDefaultRoot();
      applySessionRoot((reply && reply.path) || "");
    } catch (_) {
      applySessionRoot("");
    }
    const override = ws.get("fileRoot.override") || "";
    applyRoot(override || sessionRoot, { broadcast: false });
  }

  // Live-update the session-dir line so the user can see the current
  // terminal's cwd as it changes (OSC 7 etc.). The active tree root is left
  // alone — pressing "Apply" still rebinds it explicitly.
  async function pollSessionDir() {
    try {
      const reply = await window.cmuxProSidebar.getDefaultRoot();
      const next = (reply && reply.path) || "";
      if (next !== sessionRoot) {
        applySessionRoot(next);
      }
    } catch (_) {}
  }
  setInterval(pollSessionDir, 1000);

  if (chooseBtn) {
    chooseBtn.addEventListener("click", async () => {
      try {
        const reply = await window.cmuxProSidebar.chooseDirectory(currentRoot || sessionRoot);
        if (reply && reply.path) {
          ws.set("fileRoot.override", reply.path);
          applyRoot(reply.path);
        }
      } catch (_) {}
    });
  }

  if (resetBtn) {
    resetBtn.addEventListener("click", async () => {
      ws.clear("fileRoot.override");
      try {
        const reply = await window.cmuxProSidebar.getDefaultRoot();
        applySessionRoot((reply && reply.path) || "");
      } catch (_) {}
      applyRoot(sessionRoot);
    });
  }

  if (refreshBtn) {
    refreshBtn.addEventListener("click", () => tree.refresh());
  }

  document.addEventListener("cmux:fileRoot:changed", (e) => {
    const next = e && e.detail && e.detail.path;
    if (typeof next === "string" && next !== currentRoot) {
      applyRoot(next, { broadcast: false });
    }
  });

  if (window.cmuxProSidebar && typeof window.cmuxProSidebar.ready === "function") {
    window.cmuxProSidebar.ready("fileRoot");
  }
  ws.bind(reload);
})();
