// Shared file-tree renderer used by the File Root and File WorkTree tabs.
// Lazy expansion, per-directory cache, click-to-open via bridge.openFile.
//
// Usage:
//   const tree = window.cmuxProSidebarTree.create({ rootEl, statusEl });
//   tree.setRoot("/Users/liam/apps/okok");
//   tree.clear();
(function () {
  function joinPath(base, name) {
    if (!base) return name;
    if (base.endsWith("/")) return base + name;
    return base + "/" + name;
  }

  function fileIcon(entry) {
    if (entry.isDir) return "📁";
    if (entry.isSymlink) return "🔗";
    const lower = entry.name.toLowerCase();
    if (lower.endsWith(".md") || lower.endsWith(".markdown")) return "📝";
    if (lower.endsWith(".json")) return "🔣";
    if (lower.endsWith(".png") || lower.endsWith(".jpg") || lower.endsWith(".jpeg") || lower.endsWith(".gif") || lower.endsWith(".webp")) return "🖼";
    return "📄";
  }

  function create({ rootEl, statusEl, storageKey }) {
    if (!rootEl) throw new Error("tree.create: rootEl required");
    let currentRoot = "";
    let expanded = new Set();
    const dirCache = new Map();

    // Per-workspace persistence for the expanded-folder set. Keyed via
    // `cmuxProSidebarWorkspace` so each workspace keeps its own state and
    // survives workspace switches (and app restarts).
    function loadExpanded() {
      if (!storageKey) return new Set();
      const ws = window.cmuxProSidebarWorkspace;
      if (!ws) return new Set();
      const raw = ws.get(storageKey);
      if (!raw) return new Set();
      try {
        const arr = JSON.parse(raw);
        return new Set(Array.isArray(arr) ? arr : []);
      } catch (_) {
        return new Set();
      }
    }

    function saveExpanded() {
      if (!storageKey) return;
      const ws = window.cmuxProSidebarWorkspace;
      if (!ws) return;
      if (expanded.size === 0) {
        ws.clear(storageKey);
      } else {
        ws.set(storageKey, JSON.stringify([...expanded]));
      }
    }
    // Per-path git status from the most recent fetch.
    let statusByPath = new Map();
    // Aggregated status for ancestor folders. "modified" beats "untracked".
    let folderStatusByPath = new Map();

    async function loadGitStatus() {
      statusByPath = new Map();
      folderStatusByPath = new Map();
      if (!currentRoot) return;
      let reply;
      try {
        reply = await window.cmuxProSidebar.getGitStatus(currentRoot);
      } catch (_) {
        return;
      }
      const map = (reply && reply.statuses) || {};
      const rootSlash = currentRoot.endsWith("/") ? currentRoot : currentRoot + "/";
      for (const relPath of Object.keys(map)) {
        const code = map[relPath];
        const abs = rootSlash + relPath;
        statusByPath.set(abs, code);
        // Walk ancestors up to (but not including) currentRoot.
        let parent = abs;
        while (true) {
          const slash = parent.lastIndexOf("/");
          if (slash <= 0) break;
          parent = parent.slice(0, slash);
          if (parent.length <= currentRoot.length) break;
          const existing = folderStatusByPath.get(parent);
          if (code === "modified" || !existing) {
            folderStatusByPath.set(parent, code);
          }
        }
      }
    }

    function statusForPath(fullPath, isDir) {
      if (isDir) return folderStatusByPath.get(fullPath);
      return statusByPath.get(fullPath);
    }

    function setStatus(text) {
      if (statusEl) statusEl.textContent = text || "";
    }

    async function loadDir(path) {
      if (dirCache.has(path)) return dirCache.get(path);
      const reply = await window.cmuxProSidebar.listDir(path);
      const entries = (reply && reply.entries) || [];
      dirCache.set(path, entries);
      return entries;
    }

    async function render() {
      rootEl.innerHTML = "";
      if (!currentRoot) {
        setStatus("no root selected");
        return;
      }
      setStatus("loading…");
      let entries;
      try {
        entries = await loadDir(currentRoot);
      } catch (err) {
        setStatus(`error: ${err && err.message}`);
        return;
      }
      if (!entries.length) {
        setStatus("empty directory");
        return;
      }
      setStatus(`${entries.length} entries`);
      for (const entry of entries) {
        const li = await makeRowAndExpand(entry, currentRoot, 0);
        rootEl.appendChild(li);
      }
    }

    // Build a row for `entry` and, if it's a directory the user previously
    // had expanded, recursively render its children. Used by render() so
    // refresh() preserves the expanded state across redraws.
    async function makeRowAndExpand(entry, parentPath, depth) {
      const fullPath = joinPath(parentPath, entry.name);
      const li = makeRow(entry, parentPath, depth);
      if (!entry.isDir || !expanded.has(fullPath)) return li;

      let children;
      try {
        children = await loadDir(fullPath);
      } catch (_) {
        // Folder gone or unreadable since last expand — fall back to collapsed.
        expanded.delete(fullPath);
        saveExpanded();
        const chev = li.querySelector(":scope > .tree-row > .tree-chevron");
        if (chev) chev.textContent = "▸";
        return li;
      }
      const ul = document.createElement("ul");
      for (const child of children) {
        const childLi = await makeRowAndExpand(child, fullPath, depth + 1);
        ul.appendChild(childLi);
      }
      li.appendChild(ul);
      return li;
    }

    function makeRow(entry, parentPath, depth) {
      const fullPath = joinPath(parentPath, entry.name);
      const li = document.createElement("li");
      li.dataset.path = fullPath;

      const row = document.createElement("div");
      row.className = "tree-row";
      row.style.paddingLeft = `${4 + depth * 12}px`;

      const chevron = document.createElement("span");
      chevron.className = "tree-chevron";
      if (entry.isDir) {
        chevron.textContent = expanded.has(fullPath) ? "▾" : "▸";
      } else {
        chevron.classList.add("placeholder");
      }
      row.appendChild(chevron);

      const icon = document.createElement("span");
      icon.className = "tree-icon";
      icon.textContent = fileIcon(entry);
      row.appendChild(icon);

      const name = document.createElement("span");
      name.className = "tree-name";
      if (entry.isSymlink) name.classList.add("is-symlink");
      const status = statusForPath(fullPath, entry.isDir);
      if (status === "modified") name.classList.add("git-modified");
      else if (status === "untracked") name.classList.add("git-untracked");
      name.textContent = entry.name;
      name.title = fullPath;
      row.appendChild(name);

      row.addEventListener("click", async (e) => {
        e.stopPropagation();
        if (entry.isDir) {
          await toggleDir(li, fullPath, depth);
        } else {
          try {
            await window.cmuxProSidebar.openFile(fullPath);
          } catch (_) {}
        }
      });

      li.appendChild(row);
      return li;
    }

    async function toggleDir(li, fullPath, depth) {
      if (expanded.has(fullPath)) {
        expanded.delete(fullPath);
        saveExpanded();
        const sub = li.querySelector(":scope > ul");
        if (sub) sub.remove();
        const chev = li.querySelector(":scope > .tree-row > .tree-chevron");
        if (chev) chev.textContent = "▸";
        return;
      }
      expanded.add(fullPath);
      saveExpanded();
      const chev = li.querySelector(":scope > .tree-row > .tree-chevron");
      if (chev) chev.textContent = "▾";
      let children;
      try {
        children = await loadDir(fullPath);
      } catch (err) {
        const errLi = document.createElement("li");
        errLi.style.paddingLeft = `${4 + (depth + 1) * 12}px`;
        errLi.style.fontSize = "10px";
        errLi.style.color = "var(--secondary)";
        errLi.textContent = `error: ${err && err.message}`;
        const ul = document.createElement("ul");
        ul.appendChild(errLi);
        li.appendChild(ul);
        return;
      }
      const ul = document.createElement("ul");
      for (const child of children) {
        ul.appendChild(makeRow(child, fullPath, depth + 1));
      }
      li.appendChild(ul);
    }

    async function setRootAsync(next) {
      currentRoot = next;
      // Reload expansion state from the now-current workspace's storage so
      // switching workspaces (which changes the workspace-scoped key) picks
      // up that workspace's open folders instead of clearing them.
      expanded = loadExpanded();
      dirCache.clear();
      await loadGitStatus();
      await render();
    }

    return {
      setRoot(path) {
        // Always re-run setRootAsync: even when `path` equals the current
        // root, the workspace may have changed and `expanded` must be
        // reloaded from the new workspace's namespace.
        setRootAsync(path || "");
      },
      clear() {
        currentRoot = "";
        // In-memory only — keep the persisted set so the user's open folders
        // come back when the tree is re-mounted with a valid root.
        expanded = new Set();
        dirCache.clear();
        statusByPath = new Map();
        folderStatusByPath = new Map();
        rootEl.innerHTML = "";
        setStatus("");
      },
      refresh() {
        // Keep `expanded` so the user's open folders survive the refresh;
        // only invalidate the directory cache so disk changes are picked up.
        // Preserve scroll position by restoring scrollTop after render fills
        // the tree back in.
        const savedScroll = rootEl.scrollTop;
        dirCache.clear();
        loadGitStatus()
          .then(() => render())
          .then(() => { rootEl.scrollTop = savedScroll; });
      },
      get root() { return currentRoot; },
    };
  }

  window.cmuxProSidebarTree = { create };
})();
