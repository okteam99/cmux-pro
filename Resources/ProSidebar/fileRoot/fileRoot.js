(function () {
  const STORAGE_KEY = "cmuxProSidebar.fileRoot.override";
  const display = document.getElementById("root-display");
  const sessionDisplay = document.getElementById("session-display");
  const chooseBtn = document.getElementById("root-choose");
  const resetBtn = document.getElementById("root-reset");
  const refreshBtn = document.getElementById("root-refresh");
  const treeEl = document.getElementById("tree");
  const status = document.getElementById("tree-status");

  const tree = window.cmuxProSidebarTree.create({ rootEl: treeEl, statusEl: status });
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

  async function loadInitial() {
    try {
      const reply = await window.cmuxProSidebar.getDefaultRoot();
      applySessionRoot((reply && reply.path) || "");
    } catch (_) {
      applySessionRoot("");
    }
    const override = localStorage.getItem(STORAGE_KEY);
    applyRoot(override || sessionRoot, { broadcast: false });
  }

  if (chooseBtn) {
    chooseBtn.addEventListener("click", async () => {
      try {
        const reply = await window.cmuxProSidebar.chooseDirectory(currentRoot || sessionRoot);
        if (reply && reply.path) {
          localStorage.setItem(STORAGE_KEY, reply.path);
          applyRoot(reply.path);
        }
      } catch (_) {}
    });
  }

  if (refreshBtn) {
    refreshBtn.addEventListener("click", () => {
      tree.refresh();
    });
  }

  if (resetBtn) {
    resetBtn.addEventListener("click", async () => {
      localStorage.removeItem(STORAGE_KEY);
      try {
        const reply = await window.cmuxProSidebar.getDefaultRoot();
        applySessionRoot((reply && reply.path) || "");
      } catch (_) {}
      applyRoot(sessionRoot);
    });
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
  loadInitial();
})();
