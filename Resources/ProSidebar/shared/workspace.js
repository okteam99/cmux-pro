// Workspace-scoped state helpers. Tab scripts call
// `cmuxProSidebarWorkspace.bind(reload)` to install a workspace-change
// listener and get a typed accessor for localStorage keys namespaced by the
// active workspace UUID.
(function () {
  let workspaceId = "";

  async function refreshWorkspaceId() {
    try {
      const reply = await window.cmuxProSidebar.getWorkspaceId();
      workspaceId = (reply && reply.id) || "";
    } catch (_) {
      workspaceId = "";
    }
    return workspaceId;
  }

  function key(suffix) {
    if (!workspaceId) return `cmuxProSidebar.global.${suffix}`;
    return `cmuxProSidebar.${workspaceId}.${suffix}`;
  }

  function get(suffix) {
    return localStorage.getItem(key(suffix));
  }

  function set(suffix, value) {
    if (value == null || value === "") {
      localStorage.removeItem(key(suffix));
    } else {
      localStorage.setItem(key(suffix), value);
    }
  }

  function clear(suffix) {
    localStorage.removeItem(key(suffix));
  }

  // Install a listener that re-fetches the workspace id and invokes `reload`
  // (the tab's reload-state function) whenever the active workspace changes.
  // Also runs `reload` once on first call so the tab boots with the right
  // namespace. Polls in addition to the Swift-side notification so surface
  // (terminal-tab) focus changes within the same workspace are picked up
  // even though those don't fire `proSidebarWorkspaceDidChange`.
  async function bind(reload) {
    await refreshWorkspaceId();
    async function syncIfChanged() {
      const previous = workspaceId;
      let next = previous;
      try {
        const reply = await window.cmuxProSidebar.getWorkspaceId();
        next = (reply && reply.id) || "";
      } catch (_) {
        return;
      }
      if (next !== previous) {
        workspaceId = next;
        try { await reload(); } catch (_) {}
      }
    }
    window.addEventListener("cmux:workspaceDidChange", async (e) => {
      workspaceId = (e && e.detail && e.detail.id) || workspaceId;
      try { await reload(); } catch (_) {}
    });
    setInterval(syncIfChanged, 1500);
    try { await reload(); } catch (_) {}
  }

  window.cmuxProSidebarWorkspace = { bind, get, set, clear, key, get id() { return workspaceId; } };
})();
