// Shared bridge between Pro sidebar tabs and the native side.
// Each tab loads this before its own bundle. Public API is `window.cmuxProSidebar`.
(function () {
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cmuxProSidebar;
  const pending = new Map();

  function nextReplyId() {
    return "r" + Math.random().toString(36).slice(2) + Date.now().toString(36);
  }

  function post(kind, body) {
    if (!handler) return;
    handler.postMessage(Object.assign({ kind }, body || {}));
  }

  function call(kind, body) {
    if (!handler) {
      return Promise.reject(new Error("cmuxProSidebar bridge unavailable"));
    }
    const replyId = nextReplyId();
    return new Promise((resolve, reject) => {
      pending.set(replyId, { resolve, reject });
      try {
        handler.postMessage(Object.assign({ kind, replyId }, body || {}));
      } catch (err) {
        pending.delete(replyId);
        reject(err);
      }
    });
  }

  window.__cmuxProSidebarResolve = function (replyId, result) {
    const entry = pending.get(replyId);
    if (!entry) return;
    pending.delete(replyId);
    if (result && result.ok === false) {
      entry.reject(new Error(result.error || "bridge error"));
    } else {
      entry.resolve(result);
    }
  };

  window.cmuxProSidebar = {
    ready(mode) {
      post("ready", { mode });
    },
    ping(payload) {
      return call("ping", { payload });
    },
    getDefaultRoot() {
      return call("getDefaultRoot");
    },
    getWorkspaceId() {
      return call("getWorkspaceId");
    },
    chooseDirectory(initialPath) {
      return call("chooseDirectory", { initialPath: initialPath || null });
    },
    listGitWorktrees(rootPath) {
      return call("listGitWorktrees", { rootPath });
    },
    listDir(path, options) {
      return call("listDir", {
        path,
        includeHidden: !!(options && options.includeHidden),
      });
    },
    openFile(path) {
      return call("openFile", { path });
    },
    revealInFinder(path) {
      return call("revealInFinder", { path });
    },
    getGitStatus(rootPath) {
      return call("getGitStatus", { rootPath });
    },
  };
})();
