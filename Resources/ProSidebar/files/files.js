(function () {
  const button = document.getElementById("ping-btn");
  const resultEl = document.getElementById("ping-result");

  if (window.cmuxProSidebar && typeof window.cmuxProSidebar.ready === "function") {
    window.cmuxProSidebar.ready("files");
  }

  if (button) {
    button.addEventListener("click", async () => {
      const sentAt = new Date().toISOString();
      resultEl.textContent = "pinging…";
      try {
        const reply = await window.cmuxProSidebar.ping(sentAt);
        resultEl.textContent = `echo=${reply.echo} ok=${reply.ok}`;
      } catch (err) {
        resultEl.textContent = `error: ${err && err.message}`;
      }
    });
  }
})();
