(() => {
  if (window.__fluxDownloadHooked) return;
  window.__fluxDownloadHooked = true;

  const report = (url, mime) => {
    if (typeof url !== "string" || !(url.startsWith("http://") || url.startsWith("https://"))) return;
    window.postMessage({ source: "fluxdownload", type: "media-url", url, mime: mime || "" }, "*");
  };

  const originalFetch = window.fetch;
  if (typeof originalFetch === "function") {
    window.fetch = function fluxFetch(input, init) {
      try {
        const url = typeof input === "string" ? input : input && input.url;
        report(url);
      } catch {
        // ignore
      }
      return originalFetch.apply(this, arguments);
    };
  }

  const originalOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function fluxOpen(method, url) {
    try {
      report(String(url));
    } catch {
      // ignore
    }
    return originalOpen.apply(this, arguments);
  };

  const sendPlayer = () => {
    try {
      const data = window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.streamingData;
      if (!data) return;
      const rows = [...(data.formats || []), ...(data.adaptiveFormats || [])]
        .filter((row) => typeof row.url === "string")
        .map((row) => ({
          url: row.url,
          mimeType: row.mimeType || "",
          height: row.height || null,
          label: row.qualityLabel || null,
          contentLength: row.contentLength || null,
          fps: row.fps || null
        }));
      if (rows.length) {
        window.postMessage({ source: "fluxdownload", type: "player-formats", formats: rows }, "*");
      }
    } catch {
      // ignore
    }
  };

  sendPlayer();
  document.addEventListener("yt-navigate-finish", sendPlayer, true);
  setTimeout(sendPlayer, 1200);
  setTimeout(sendPlayer, 4000);
})();
