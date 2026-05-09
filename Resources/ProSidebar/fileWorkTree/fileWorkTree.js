(function () {
  const STORAGE_KEY = "cmuxProSidebar.fileRoot.override";
  const SELECTED_WT_KEY = "cmuxProSidebar.fileWorkTree.selectedPath";
  const select = document.getElementById("worktree-select");
  const meta = document.getElementById("worktree-meta");
  const refreshBtn = document.getElementById("refresh-btn");
  const treeRefreshBtn = document.getElementById("tree-refresh");
  const treeEl = document.getElementById("tree");
  const treeStatus = document.getElementById("tree-status");

  const tree = window.cmuxProSidebarTree.create({ rootEl: treeEl, statusEl: treeStatus });
  let sessionRoot = "";
  let worktrees = [];
  let selectedPath = "";

  function setMeta(text) {
    if (meta) meta.textContent = text || "";
  }

  function shortenBranch(branchRef) {
    if (!branchRef) return "(detached)";
    return branchRef.replace(/^refs\/heads\//, "");
  }

  function shortHead(sha) {
    return sha ? sha.slice(0, 7) : "";
  }

  function relativePath(base, target) {
    if (!base || !target) return target || "";
    if (target === base) return ".";
    const baseParts = base.replace(/\/+$/, "").split("/").filter(Boolean);
    const targetParts = target.replace(/\/+$/, "").split("/").filter(Boolean);
    let i = 0;
    while (i < baseParts.length && i < targetParts.length && baseParts[i] === targetParts[i]) i++;
    const ups = baseParts.length - i;
    const remaining = targetParts.slice(i);
    const segments = [];
    for (let k = 0; k < ups; k++) segments.push("..");
    for (const seg of remaining) segments.push(seg);
    return segments.length === 0 ? "." : segments.join("/");
  }

  function updateMetaForSelection() {
    const wt = worktrees.find(w => w.path === selectedPath);
    if (wt) {
      setMeta(`${shortenBranch(wt.branch)} · ${shortHead(wt.head)}`);
    } else {
      setMeta("");
    }
  }

  function applySelection(path) {
    selectedPath = path || "";
    if (selectedPath) {
      localStorage.setItem(SELECTED_WT_KEY, selectedPath);
    }
    tree.setRoot(selectedPath);
    updateMetaForSelection();
  }

  function render(currentRoot) {
    if (!select) return;
    select.innerHTML = "";
    if (!worktrees.length) {
      const opt = document.createElement("option");
      opt.textContent = "(no worktrees)";
      opt.disabled = true;
      opt.selected = true;
      select.appendChild(opt);
      setMeta(currentRoot ? "not a git repo or no linked worktrees" : "no root");
      select.disabled = true;
      tree.clear();
      selectedPath = "";
      return;
    }
    select.disabled = false;
    const base = sessionRoot || currentRoot || worktrees[0].path;
    for (const wt of worktrees) {
      const opt = document.createElement("option");
      opt.value = wt.path || "";
      const rel = relativePath(base, wt.path || "");
      const branch = shortenBranch(wt.branch);
      opt.textContent = `${rel}  ·  ${branch}`;
      select.appendChild(opt);
    }
    // Pick a selection: previously remembered → else the worktree matching the
    // current root → else the first.
    const remembered = localStorage.getItem(SELECTED_WT_KEY) || "";
    let initial = worktrees.find(w => w.path === remembered)
              || worktrees.find(w => w.path === currentRoot)
              || worktrees[0];
    select.value = initial.path;
    applySelection(initial.path);
  }

  async function refresh() {
    setMeta("loading…");
    let rootPath = localStorage.getItem(STORAGE_KEY) || "";
    try {
      const reply = await window.cmuxProSidebar.getDefaultRoot();
      sessionRoot = (reply && reply.path) || "";
    } catch (_) {
      sessionRoot = "";
    }
    if (!rootPath) rootPath = sessionRoot;
    if (!rootPath) {
      worktrees = [];
      render("");
      return;
    }
    try {
      const reply = await window.cmuxProSidebar.listGitWorktrees(rootPath);
      worktrees = (reply && reply.worktrees) || [];
      render(rootPath);
    } catch (err) {
      setMeta(`error: ${err && err.message}`);
    }
  }

  if (select) {
    select.addEventListener("change", () => {
      const value = select.value;
      if (!value) return;
      applySelection(value);
    });
  }
  if (refreshBtn) {
    refreshBtn.addEventListener("click", async () => {
      await refresh();
      tree.refresh();
    });
  }
  if (treeRefreshBtn) {
    treeRefreshBtn.addEventListener("click", () => tree.refresh());
  }

  if (window.cmuxProSidebar && typeof window.cmuxProSidebar.ready === "function") {
    window.cmuxProSidebar.ready("fileWorkTree");
  }
  refresh();
})();
