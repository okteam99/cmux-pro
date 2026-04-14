/* cmux Markdown Viewer · front-end.
 * Receives `cmux.applyState(state)` calls from native side. Renders via marked
 * + highlight.js + mermaid. Posts back via webkit.messageHandlers.cmux.
 *
 * State contract (injected by native):
 *   {
 *     filePath: string,
 *     content: string,
 *     isFileUnavailable: boolean,
 *     isTruncated: boolean,
 *     theme: "light" | "dark",
 *     l10n: { [key: string]: string }
 *   }
 */
(function () {
  "use strict";

  const bridge = {
    post(msg) {
      try {
        window.webkit.messageHandlers.cmux.postMessage(msg);
      } catch (e) {
        // Bridge may be missing during static preview; swallow.
      }
    },
  };

  const state = {
    strings: {},
    lastViewportSnapshot: null,
    mermaidInited: false,
    highlightInited: false,
    lastTheme: null,
  };

  function t(key, fallback) {
    return (state.strings && state.strings[key]) || fallback;
  }

  function setTheme(theme) {
    const isDark = theme === "dark";
    document.documentElement.classList.toggle("dark", isDark);
    if (state.lastTheme !== theme) {
      state.lastTheme = theme;
      if (state.mermaidInited && window.mermaid) {
        try {
          window.mermaid.initialize({
            startOnLoad: false,
            theme: isDark ? "dark" : "default",
            securityLevel: "strict",
          });
        } catch (e) {
          // ignore
        }
      }
    }
  }

  function captureViewport() {
    const scrollTop = window.scrollY || document.documentElement.scrollTop;
    const scrollHeight = document.documentElement.scrollHeight;
    const viewportHeight = window.innerHeight;
    const scrollTopRatio = scrollHeight > 0 ? scrollTop / scrollHeight : 0;

    // Find closest heading at-or-above viewport top
    const headings = document.querySelectorAll(
      "#content h1[id], #content h2[id], #content h3[id], #content h4[id], #content h5[id], #content h6[id]"
    );
    let anchorId = null;
    let offsetInAnchor = null;
    for (const h of headings) {
      const rect = h.getBoundingClientRect();
      if (rect.top <= 0) {
        anchorId = h.id;
        offsetInAnchor =
          viewportHeight > 0 ? -rect.top / viewportHeight : 0;
      } else {
        break;
      }
    }
    state.lastViewportSnapshot = {
      anchorId,
      offsetInAnchor,
      scrollTopRatio,
    };
    return state.lastViewportSnapshot;
  }

  function restoreViewport(snapshot) {
    if (!snapshot) return "none";
    if (snapshot.anchorId) {
      const el = document.getElementById(snapshot.anchorId);
      if (el) {
        el.scrollIntoView({ block: "start" });
        if (typeof snapshot.offsetInAnchor === "number") {
          window.scrollBy(0, snapshot.offsetInAnchor * window.innerHeight);
        }
        return "anchor";
      }
    }
    if (typeof snapshot.scrollTopRatio === "number") {
      const h = document.documentElement.scrollHeight;
      window.scrollTo({ top: snapshot.scrollTopRatio * h });
      return "ratio";
    }
    return "none";
  }

  function renderMarkdown(rawContent) {
    if (!window.marked) return escapeHtml(rawContent);
    const renderer = new window.marked.Renderer();
    // Custom image: local file:// paths or relative paths → local-image;
    // http(s) → external-image-blocked. Only data: / file: inline.
    renderer.image = function (tokenOrHref, title, text) {
      const token = tokenOrHref && typeof tokenOrHref === "object" ? tokenOrHref : null;
      const href = token ? token.href : tokenOrHref;
      const imageTitle = token ? token.title : title;
      const imageText = token ? token.text : text;
      if (!href) return "";
      if (/^(data:|file:)/.test(href)) {
        const titleAttr = imageTitle ? ` title="${escapeAttr(imageTitle)}"` : "";
        return `<img src="${escapeAttr(href)}" alt="${escapeAttr(imageText || "")}"${titleAttr}>`;
      }
      if (/^https?:\/\//.test(href)) {
        const msg = t("markdownViewer.externalImage.blocked", "External image blocked: %@");
        const filled = msg.replace("%@", href);
        return `<span class="external-image-blocked" data-href="${escapeAttr(href)}">${escapeHtml(filled)}</span>`;
      }
      // Relative path or absolute file path without scheme → local image
      const hint = t("markdownViewer.localImage.hint", "(local image · click to open)");
      const tooltip = t("markdownViewer.localImage.tooltip", "Open in default app");
      return `<a href="#" class="local-image" data-local-path="${escapeAttr(href)}" title="${escapeAttr(tooltip)}">${escapeHtml(imageText || hint)}</a>`;
    };

    // Heading id slug generation for AC-16 anchor navigation
    renderer.heading = function (tokenOrText, level, raw) {
      const token = tokenOrText && typeof tokenOrText === "object" ? tokenOrText : null;
      const depth = token ? token.depth : level;
      const plainText = token ? token.text : raw;
      const htmlText = token
        ? renderInlineTokenText(this, token)
        : String(tokenOrText || "");
      const slug = slugify(plainText || htmlText);
      return `<h${depth} id="${escapeAttr(slug)}">${htmlText}</h${depth}>`;
    };

    window.marked.setOptions({
      renderer,
      breaks: false,
      gfm: true,
      headerIds: false, // we do our own
      mangle: false,
    });

    const html = window.marked.parse(rawContent);
    return html;
  }

  function renderInlineTokenText(renderer, token) {
    if (token.tokens && renderer.parser && renderer.parser.parseInline) {
      try {
        return renderer.parser.parseInline(token.tokens);
      } catch (e) {
        // Fall through to escaped plain text.
      }
    }
    return escapeHtml(token.text || "");
  }

  function slugify(text) {
    return String(text)
      .toLowerCase()
      .trim()
      .replace(/[^\w\s-]/g, "")
      .replace(/\s+/g, "-")
      .slice(0, 80) || "section";
  }

  function applyHighlight(root) {
    if (!window.hljs) return;
    if (!state.highlightInited) {
      state.highlightInited = true;
    }
    root.querySelectorAll("pre code").forEach((block) => {
      try {
        window.hljs.highlightElement(block);
      } catch (e) {
        // ignore
      }
    });
    // Wrap <pre> so the copy button can position relative
    root.querySelectorAll("pre").forEach((pre) => {
      if (pre.parentElement && pre.parentElement.classList.contains("pre-wrap")) return;
      const wrap = document.createElement("div");
      wrap.className = "pre-wrap";
      pre.parentNode.insertBefore(wrap, pre);
      wrap.appendChild(pre);

      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "copy-btn";
      btn.setAttribute("aria-label", t("markdownViewer.codeblock.copy.aria", "Copy code to clipboard"));
      btn.textContent = t("markdownViewer.codeblock.copy", "Copy");
      btn.addEventListener("click", () => {
        const text = pre.querySelector("code")?.innerText ?? "";
        bridge.post({ kind: "copyCode", text });
        btn.textContent = t("markdownViewer.codeblock.copied", "Copied");
        setTimeout(() => {
          btn.textContent = t("markdownViewer.codeblock.copy", "Copy");
        }, 1200);
      });
      wrap.appendChild(btn);
    });
  }

  async function applyMermaid(root) {
    if (!window.mermaid) return;
    if (!state.mermaidInited) {
      try {
        window.mermaid.initialize({
          startOnLoad: false,
          theme: state.lastTheme === "dark" ? "dark" : "default",
          securityLevel: "strict",
        });
        state.mermaidInited = true;
      } catch (e) {
        /* ignore */
      }
    }

    // Detect both ```mermaid blocks and raw ```graph TD style that user wrote
    // without explicit "mermaid" tag. If the first non-empty line begins with
    // a mermaid diagram keyword, treat the block as mermaid.
    const mermaidKeywords = /^\s*(graph|flowchart|sequenceDiagram|classDiagram|stateDiagram|erDiagram|gantt|pie|mindmap|journey|gitGraph|quadrantChart|requirementDiagram|timeline)\b/i;

    const codeBlocks = root.querySelectorAll("pre > code");
    const figures = [];
    codeBlocks.forEach((code) => {
      let isMermaid = false;
      code.classList.forEach((cls) => {
        if (cls === "language-mermaid" || cls === "mermaid") isMermaid = true;
      });
      if (!isMermaid) {
        const firstLine = (code.textContent || "").split("\n")[0] || "";
        if (mermaidKeywords.test(firstLine)) isMermaid = true;
      }
      if (!isMermaid) return;

      const pre = code.parentElement;
      const wrap = pre.parentElement?.classList.contains("pre-wrap") ? pre.parentElement : pre;
      const source = code.textContent || "";

      const figure = document.createElement("div");
      figure.className = "mermaid-figure";
      figure.innerHTML = `<div class="mermaid-loading">${escapeHtml(t("markdownViewer.mermaid.loading", "Rendering diagram…"))}</div>`;
      wrap.parentNode.replaceChild(figure, wrap);
      figures.push({ figure, source });
    });

    let errors = [];
    for (const { figure, source } of figures) {
      try {
        const id = "m_" + Math.random().toString(36).slice(2);
        const { svg } = await window.mermaid.render(id, source);
        figure.innerHTML = svg;
        enableMermaidPreview(figure);
      } catch (e) {
        errors.push(String(e && e.message ? e.message : e));
        const errTitle = t("markdownViewer.mermaid.error", "Failed to render Mermaid diagram.");
        figure.innerHTML =
          `<div class="mermaid-error"><div>${escapeHtml(errTitle)}</div>` +
          `<pre class="mermaid-error-fallback">${escapeHtml(source)}</pre></div>`;
      }
    }
    if (figures.length > 0) {
      bridge.post({
        kind: "mermaid",
        totalCount: figures.length,
        errorCount: errors.length,
        errors,
      });
    }
  }

  function enableMermaidPreview(figure) {
    const svg = figure.querySelector("svg");
    if (!svg) return;
    const label = t("markdownViewer.diagram.expand", "Expand diagram");
    figure.classList.add("is-clickable");
    figure.setAttribute("role", "button");
    figure.setAttribute("tabindex", "0");
    figure.setAttribute("aria-label", label);

    const open = () => openDiagramPreview(svg);
    figure.addEventListener("click", open);
    figure.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        open();
      }
    });
  }

  function openDiagramPreview(svg) {
    closeDiagramPreview();
    const closeLabel = t("markdownViewer.diagram.close", "Close diagram preview");
    const zoomInLabel = t("markdownViewer.diagram.zoomIn", "Zoom in");
    const zoomOutLabel = t("markdownViewer.diagram.zoomOut", "Zoom out");
    const resetZoomLabel = t("markdownViewer.diagram.resetZoom", "Reset zoom");
    const src =
      "data:image/svg+xml;charset=utf-8," +
      encodeURIComponent(new XMLSerializer().serializeToString(svg));

    const overlay = document.createElement("div");
    overlay.className = "diagram-lightbox";
    overlay.setAttribute("role", "dialog");
    overlay.setAttribute("aria-modal", "true");
    overlay.setAttribute("aria-label", closeLabel);
    overlay.innerHTML =
      `<div class="diagram-lightbox-toolbar">` +
      `<button type="button" class="diagram-lightbox-tool" data-action="zoom-out" aria-label="${escapeAttr(zoomOutLabel)}">−</button>` +
      `<button type="button" class="diagram-lightbox-tool diagram-lightbox-zoom" data-action="reset-zoom" aria-label="${escapeAttr(resetZoomLabel)}">100%</button>` +
      `<button type="button" class="diagram-lightbox-tool" data-action="zoom-in" aria-label="${escapeAttr(zoomInLabel)}">+</button>` +
      `</div>` +
      `<button type="button" class="diagram-lightbox-close" aria-label="${escapeAttr(closeLabel)}">×</button>` +
      `<div class="diagram-lightbox-content"><img alt="${escapeAttr(t("markdownViewer.diagram.expand", "Expand diagram"))}" src="${src}"></div>`;

    let zoom = 1;
    const img = overlay.querySelector(".diagram-lightbox-content img");
    const zoomLabel = overlay.querySelector(".diagram-lightbox-zoom");
    const applyZoom = () => {
      img.style.width = `${Math.round(zoom * 100)}%`;
      zoomLabel.textContent = `${Math.round(zoom * 100)}%`;
    };
    const changeZoom = (delta) => {
      zoom = Math.min(4, Math.max(0.5, Math.round((zoom + delta) * 10) / 10));
      applyZoom();
    };

    const close = () => closeDiagramPreview();
    overlay.addEventListener("click", (event) => {
      if (event.target === overlay) close();
    });
    overlay.querySelector(".diagram-lightbox-close").addEventListener("click", close);
    overlay.querySelector("[data-action='zoom-out']").addEventListener("click", () => changeZoom(-0.1));
    overlay.querySelector("[data-action='zoom-in']").addEventListener("click", () => changeZoom(0.1));
    overlay.querySelector("[data-action='reset-zoom']").addEventListener("click", () => {
      zoom = 1;
      applyZoom();
    });

    const onKeyDown = (event) => {
      if (event.key === "Escape") {
        close();
      } else if ((event.key === "+" || event.key === "=") && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        changeZoom(0.1);
      } else if (event.key === "-" && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        changeZoom(-0.1);
      } else if (event.key === "0" && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        zoom = 1;
        applyZoom();
      }
    };
    overlay.__cmuxOnKeyDown = onKeyDown;
    document.addEventListener("keydown", onKeyDown);
    document.body.appendChild(overlay);
    applyZoom();
    overlay.querySelector(".diagram-lightbox-close").focus();
  }

  function closeDiagramPreview() {
    const overlay = document.querySelector(".diagram-lightbox");
    if (!overlay) return;
    if (overlay.__cmuxOnKeyDown) {
      document.removeEventListener("keydown", overlay.__cmuxOnKeyDown);
    }
    overlay.remove();
  }

  function installBindings(root) {
    root.querySelectorAll(".local-image").forEach((el) => {
      el.addEventListener("click", (e) => {
        e.preventDefault();
        const p = el.getAttribute("data-local-path");
        if (!p) return;
        bridge.post({ kind: "openExternal", url: "file://" + resolveRelativePath(p) });
      });
    });
    root.querySelectorAll("a[href]").forEach((el) => {
      const href = el.getAttribute("href") || "";
      if (el.classList.contains("local-image")) return;
      if (href.startsWith("#")) return; // internal anchor, default behaviour
      // Everything else: hijack and route via bridge.
      el.addEventListener("click", (e) => {
        e.preventDefault();
        bridge.post({ kind: "openExternal", url: href });
      });
    });
  }

  function resolveRelativePath(p) {
    // For AC-32 the native side owns the base dir; we just pass the raw href
    // and let native resolve. Prepend nothing special here; bridge receives
    // the string as-is and NSWorkspace.open handles file:// / relative in
    // Swift.
    return p;
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
  }
  function escapeAttr(s) { return escapeHtml(s); }

  function render(stateObj) {
    const content = document.getElementById("content");
    const empty = document.getElementById("emptyState");
    const banner = document.getElementById("banner");
    const breadcrumb = document.getElementById("breadcrumb");

    breadcrumb.textContent = stateObj.filePath || "";

    if (stateObj.isFileUnavailable) {
      content.hidden = true;
      content.innerHTML = "";
      empty.hidden = false;
      empty.className = "file-deleted";
      empty.innerHTML =
        `<div class="icon">🗑️</div>` +
        `<div class="title">${escapeHtml(t("markdownViewer.file.deleted", "The file has been deleted."))}</div>` +
        `<div class="hint">${escapeHtml(t("markdownViewer.file.deleted.hint", "Waiting for the file to reappear…"))}</div>`;
      banner.hidden = true;
      return;
    }

    if (!stateObj.content || stateObj.content.length === 0) {
      content.hidden = true;
      content.innerHTML = "";
      empty.hidden = false;
      empty.className = "empty-state";
      empty.textContent = t("markdownViewer.file.empty", "(empty)");
      banner.hidden = !stateObj.isTruncated;
      if (stateObj.isTruncated) {
        banner.textContent = t("markdownViewer.file.truncated",
          "File too large — showing first 10MB only.");
      }
      return;
    }

    // Capture viewport before rerender
    const snapshot = state.lastViewportSnapshot ? state.lastViewportSnapshot : captureViewport();

    empty.hidden = true;
    banner.hidden = !stateObj.isTruncated;
    if (stateObj.isTruncated) {
      banner.textContent = t("markdownViewer.file.truncated",
        "File too large — showing first 10MB only.");
    }

    content.hidden = false;
    content.innerHTML = renderMarkdown(stateObj.content);
    applyHighlight(content);
    applyMermaid(content).then(() => {
      // Restore viewport after async mermaid rendering settles.
      const strategy = restoreViewport(snapshot);
      bridge.post({ kind: "fileReloadAck", strategy, anchorId: snapshot?.anchorId || null });
      state.lastViewportSnapshot = null;
    });
    installBindings(content);
  }

  // Capture viewport periodically so we always have a fresh snapshot for
  // the next rerender (cheap: only when user scrolls).
  let scrollDebounce = null;
  window.addEventListener("scroll", () => {
    if (scrollDebounce) clearTimeout(scrollDebounce);
    scrollDebounce = setTimeout(() => {
      captureViewport();
      bridge.post({
        kind: "viewportStateSync",
        anchorId: state.lastViewportSnapshot?.anchorId || null,
        offsetInAnchor: state.lastViewportSnapshot?.offsetInAnchor ?? null,
        scrollTopRatio: state.lastViewportSnapshot?.scrollTopRatio ?? null,
      });
    }, 120);
  }, { passive: true });

  // Public API consumed by native.
  window.cmux = {
    applyState(next) {
      state.strings = next.l10n || state.strings;
      setTheme(next.theme || "light");
      render(next);
    },
    setTheme,
    exportMermaidSVG(_nodeId) {
      // Placeholder, P1 (PRD §5.4).
      return null;
    },
  };

  // Signal ready once DOM parse is done + libs loaded.
  window.__viewerReady = true;
  bridge.post({ kind: "viewerReady" });
})();
