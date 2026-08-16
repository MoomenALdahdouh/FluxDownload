const overlays = [];
let openPanel = null;
let refreshTimer = 0;
let orphaned = false;
let performanceObserver = null;
let mutation = null;

function fluxExtensionAlive() {
  try {
    return !orphaned && Boolean(chrome?.runtime?.id);
  } catch {
    return false;
  }
}

function fluxOrphaned() {
  if (orphaned) return;
  orphaned = true;
  try {
    mutation?.disconnect();
  } catch {
    // ignore
  }
  try {
    performanceObserver?.disconnect();
  } catch {
    // ignore
  }
  if (refreshTimer) {
    cancelAnimationFrame(refreshTimer);
    refreshTimer = 0;
  }
  window.removeEventListener("message", onPageMessage);
  window.removeEventListener("scroll", syncOverlays, true);
  window.removeEventListener("resize", syncOverlays);
  document.removeEventListener("click", onDocumentClick);
  closePanel();
  sweepOverlays(new Set());
}

function fluxRuntimeSend(message) {
  return new Promise((resolve) => {
    if (!fluxExtensionAlive()) {
      fluxOrphaned();
      resolve({ ok: false, error: "Reload this tab to reconnect FluxDownload." });
      return;
    }
    try {
      chrome.runtime.sendMessage(message, (response) => {
        let err = "";
        try {
          err = chrome.runtime?.lastError?.message || "";
        } catch {
          err = "Extension context invalidated.";
        }
        if (err) {
          if (/invalidated|context/i.test(err)) fluxOrphaned();
          resolve({
            ok: false,
            error: /invalidated|context/i.test(err)
              ? "Reload this tab to reconnect FluxDownload."
              : err
          });
          return;
        }
        resolve(response);
      });
    } catch {
      fluxOrphaned();
      resolve({ ok: false, error: "Reload this tab to reconnect FluxDownload." });
    }
  });
}

function isDRM(media) {
  return Boolean(media.mediaKeys || media.webkitKeys);
}

function playerSources(media) {
  const urls = [];
  if (media.currentSrc) urls.push(media.currentSrc);
  if (media.src) urls.push(media.src);
  media.querySelectorAll("source").forEach((source) => {
    if (source.src) urls.push(source.src);
  });
  return [...new Set(urls)];
}

function resourceCandidates() {
  const urls = [];
  try {
    performance.getEntriesByType("resource").forEach((entry) => {
      if (fluxLooksLikeMedia(entry.name, entry.initiatorType === "video" || entry.initiatorType === "audio" ? "video/*" : "")) {
        urls.push(entry.name);
      }
    });
  } catch {
    // ignore
  }
  document.querySelectorAll("source[src], video[src], audio[src], a[href]").forEach((node) => {
    const url = node.src || node.href;
    if (fluxLooksLikeMedia(url)) urls.push(url);
  });
  return [...new Set(urls.filter(fluxIsHttp))];
}

function requestSniffed() {
  return fluxRuntimeSend({ type: "media.forTab" }).then((response) => response?.formats || []);
}

async function formatsForPlayer(media) {
  const httpSources = playerSources(media).filter(fluxIsHttp);
  const nearby = resourceCandidates();
  const raw = [...httpSources, ...nearby];
  const dominant = fluxLinkedInDominantId(raw);
  const unique = [];
  const seen = new Set();
  for (const url of raw) {
    if (fluxLinkedInIsJunk(url) || !fluxLooksLikeMedia(url)) continue;
    const parts = fluxLinkedInParts(url);
    if (dominant && parts && parts.videoId !== dominant) continue;
    const key = url.split("#")[0];
    if (seen.has(key)) continue;
    seen.add(key);
    unique.push(url);
  }
  let local = [];
  for (const url of unique) {
    let host = "";
    try { host = new URL(url).hostname.toLowerCase(); } catch { /* ignore */ }
    if (host.includes("licdn.com")) {
      local.push(fluxFormatFromURL(url, "application/vnd.apple.mpegurl"));
    } else if (fluxIsHLSUrl(url)) {
      local.push(...(await fluxExpandHLS(url)));
    } else {
      const extras = {};
      if (httpSources.includes(url) && media.videoHeight) extras.height = media.videoHeight;
      local.push(fluxFormatFromURL(url, "", extras));
    }
  }
  const sniffed = (await requestSniffed()).filter((format) => {
    if (!format?.url || fluxLinkedInIsJunk(format.url)) return false;
    const parts = fluxLinkedInParts(format.url);
    if (dominant && parts && parts.videoId !== dominant) return false;
    return true;
  });
  const page = fluxExtractPageStreamingFormats();
  let formats = fluxMergeFormats([...local, ...sniffed, ...page]);
  const videoId = fluxYouTubeVideoId(location.href);
  if (videoId) {
    try {
      const resolved = await fluxResolveYouTubePlayer(videoId);
      if (resolved?.ok && resolved.formats?.length) {
        formats = fluxPresentYouTubeQualities(fluxMergeFormats([...formats, ...resolved.formats]));
      }
    } catch {
      // keep captured formats
    }
  }
  return {
    drm: isDRM(media),
    blobOnly: playerSources(media).some((url) => url.startsWith("blob:")) && httpSources.length === 0,
    formats
  };
}

function closePanel() {
  if (openPanel) {
    openPanel.remove();
    openPanel = null;
  }
}

function reasonCopy(info) {
  if (info.drm) {
    return {
      title: "Protected media",
      body: "This player uses DRM. FluxDownload cannot decrypt Netflix-style protected streams."
    };
  }
  if (info.formats.some((format) => format.protected)) {
    return {
      title: "Protected media",
      body: "The playlist is encrypted. FluxDownload will not download protected streams."
    };
  }
  return {
    title: "Waiting for the stream",
    body: "Play the video or audio (or change quality) so FluxDownload can capture the real HTTP file, the same way IDM does. Then click Download again."
  };
}

function sendFormat(format, extras = {}) {
  return fluxRuntimeSend({
    type: "media.download",
    url: format.url,
    filename: fluxFilename(format.url, format),
    mimeType: format.mimeType,
    segmentURLs: format.segmentURLs || [format.url],
    audioURL: extras.audio?.url || null,
    audioFilename: extras.audio ? fluxFilename(extras.audio.url, extras.audio) : null,
    audioMimeType: extras.audio?.mimeType || null
  });
}

function renderPanel(anchor, media, info) {
  closePanel();
  const panel = document.createElement("div");
  panel.className = "flux-panel";
  panel.setAttribute("role", "dialog");
  panel.setAttribute("aria-label", "Download media");

  const usable = info.formats.filter((format) => !format.protected);
  const blocked = info.drm || usable.length === 0;
  const bestAudio = fluxBestAudio(usable);

  const header = document.createElement("div");
  header.className = "flux-panel-header";
  const title = document.createElement("div");
  const kind = media.tagName === "AUDIO" ? "audio" : "video";
  title.innerHTML = `<strong>Download ${kind}</strong><span>${location.hostname}</span>`;
  const close = document.createElement("button");
  close.type = "button";
  close.className = "flux-icon";
  close.setAttribute("aria-label", "Close");
  close.textContent = "×";
  close.addEventListener("click", closePanel);
  header.append(title, close);
  panel.append(header);

  if (blocked) {
    const reason = reasonCopy(info);
    const empty = document.createElement("div");
    empty.className = "flux-empty";
    empty.innerHTML = `<strong>${reason.title}</strong><p>${reason.body}</p>`;
    const retry = document.createElement("button");
    retry.type = "button";
    retry.className = "flux-retry";
    retry.textContent = "Scan again";
    retry.addEventListener("click", async () => {
      retry.disabled = true;
      retry.textContent = "Scanning…";
      const next = await formatsForPlayer(media);
      renderPanel(anchor, media, next);
    });
    empty.append(retry);
    panel.append(empty);
  } else {
    const list = document.createElement("div");
    list.className = "flux-list";
    usable.forEach((format) => {
      const row = document.createElement("button");
      row.type = "button";
      row.className = "flux-row";
      const kindLabel = format.hasVideo && format.hasAudio
        ? "Video + audio"
        : format.hasVideo
          ? "Video"
          : "Audio";
      const extra = format.hasVideo && !format.hasAudio && bestAudio ? " · + audio file" : "";
      row.innerHTML = `
        <span class="flux-row-title">${format.label}</span>
        <span class="flux-row-meta">${format.container} · ${kindLabel}${extra}</span>
      `;
      row.addEventListener("click", async () => {
        list.querySelectorAll("button").forEach((button) => {
          button.disabled = true;
        });
        row.querySelector(".flux-row-meta").textContent = "Sending to FluxDownload…";
        const extras = format.hasVideo && !format.hasAudio && bestAudio ? { audio: bestAudio } : {};
        const response = await sendFormat(format, extras);
        row.querySelector(".flux-row-meta").textContent = response?.ok
          ? extras.audio
            ? "Sent video + audio to FluxDownload"
            : "Sent to FluxDownload"
          : response?.error || "Desktop app is not connected";
        if (response?.ok) setTimeout(closePanel, 800);
        else {
          list.querySelectorAll("button").forEach((button) => {
            button.disabled = false;
          });
        }
      });
      list.append(row);
    });
    panel.append(list);
    if (/youtube\.com$|youtu\.be$/i.test(location.hostname.replace(/^www\./, ""))) {
      const note = document.createElement("p");
      note.className = "flux-note";
      note.textContent = "YouTube qualities come from the video’s available streams. Progressive 360p is one file with audio; higher resolutions send a video file plus a matching audio file.";
      panel.append(note);
    }
  }

  document.documentElement.append(panel);
  openPanel = panel;
  panel._fluxMedia = media;
  panel._fluxAnchor = anchor;
  positionPanel(panel, media, anchor);
}

function mediaRectArea(media) {
  const rect = media.getBoundingClientRect();
  return Math.max(0, rect.width) * Math.max(0, rect.height);
}

function mediaOverlap(a, b) {
  const r1 = a.getBoundingClientRect();
  const r2 = b.getBoundingClientRect();
  const width = Math.max(0, Math.min(r1.right, r2.right) - Math.max(r1.left, r2.left));
  const height = Math.max(0, Math.min(r1.bottom, r2.bottom) - Math.max(r1.top, r2.top));
  const intersection = width * height;
  const union = mediaRectArea(a) + mediaRectArea(b) - intersection;
  return union > 0 ? intersection / union : 0;
}

function isUsablePlayer(media) {
  if (!media?.isConnected) return false;
  const style = window.getComputedStyle(media);
  if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return false;
  const rect = media.getBoundingClientRect();
  const minW = media.tagName === "AUDIO" ? 72 : 120;
  const minH = media.tagName === "AUDIO" ? 18 : 70;
  return rect.width >= minW && rect.height >= minH;
}

function pickPrimaryPlayers() {
  const candidates = [...document.querySelectorAll("video, audio")].filter(isUsablePlayer);
  candidates.sort((a, b) => mediaRectArea(b) - mediaRectArea(a));
  const keep = [];
  for (const media of candidates) {
    if (keep.some((other) => mediaOverlap(media, other) > 0.45)) continue;
    keep.push(media);
  }
  return keep;
}

function positionChip(chip, media) {
  if (!isUsablePlayer(media)) {
    chip.hidden = true;
    return;
  }
  chip.hidden = false;
  const rect = media.getBoundingClientRect();
  const top = window.scrollY + rect.top + 8;
  const left = window.scrollX + rect.right - 20 - 8;
  chip.style.top = `${Math.max(window.scrollY + 8, top)}px`;
  chip.style.left = `${Math.max(window.scrollX + 8, left)}px`;
}

function positionPanel(panel, media, anchor) {
  const rect = (anchor || media).getBoundingClientRect();
  panel.style.top = `${window.scrollY + rect.bottom + 8}px`;
  panel.style.left = `${Math.max(12, window.scrollX + rect.right - 320)}px`;
}

function overlayFor(media) {
  return overlays.find((entry) => entry.media === media);
}

function removeOverlay(entry) {
  entry.observer?.disconnect();
  entry.chip.remove();
}

function sweepOverlays(keep) {
  for (let index = overlays.length - 1; index >= 0; index -= 1) {
    const entry = overlays[index];
    if (!keep.has(entry.media) || !entry.media.isConnected) {
      if (openPanel?._fluxMedia === entry.media) closePanel();
      removeOverlay(entry);
      overlays.splice(index, 1);
    }
  }
  document.querySelectorAll(".flux-chip").forEach((chip) => {
    if (!overlays.some((entry) => entry.chip === chip)) chip.remove();
  });
}

function syncOverlays() {
  for (const entry of overlays) {
    positionChip(entry.chip, entry.media);
  }
  if (openPanel?._fluxMedia) {
    positionPanel(openPanel, openPanel._fluxMedia, openPanel._fluxAnchor);
  }
}

function placeOverlay(media) {
  const existing = overlayFor(media);
  if (existing) {
    positionChip(existing.chip, media);
    return existing.chip;
  }
  const chip = document.createElement("button");
  chip.type = "button";
  chip.className = "flux-chip";
  chip.textContent = "↓";
  chip.title = "Download with FluxDownload";
  chip.setAttribute("aria-label", "Download with FluxDownload");
  document.documentElement.append(chip);

  const observer = new ResizeObserver(() => positionChip(chip, media));
  observer.observe(media);
  overlays.push({ media, chip, observer });
  positionChip(chip, media);

  chip.addEventListener("click", async (event) => {
    event.preventDefault();
    event.stopPropagation();
    chip.disabled = true;
    try {
      const info = await formatsForPlayer(media);
      renderPanel(chip, media, info);
    } finally {
      chip.disabled = false;
    }
  });
  return chip;
}

function refresh() {
  if (!fluxExtensionAlive()) {
    fluxOrphaned();
    return;
  }
  if (window !== window.top && (window.innerWidth < 160 || window.innerHeight < 90)) {
    sweepOverlays(new Set());
    return;
  }
  const keep = new Set(pickPrimaryPlayers());
  sweepOverlays(keep);
  keep.forEach((media) => placeOverlay(media));
  syncOverlays();
}

function scheduleRefresh() {
  if (orphaned || refreshTimer) return;
  refreshTimer = requestAnimationFrame(() => {
    refreshTimer = 0;
    refresh();
  });
}

function onDocumentClick(event) {
  if (openPanel && !openPanel.contains(event.target) && !event.target.closest(".flux-chip")) {
    closePanel();
  }
}

function onPageMessage(event) {
  if (event.source !== window || event.data?.source !== "fluxdownload") return;
  if (!fluxExtensionAlive()) {
    fluxOrphaned();
    return;
  }
  if (event.data.type === "media-url") {
    void fluxRuntimeSend({ type: "media.observed", url: event.data.url, mimeType: event.data.mime });
  }
  if (event.data.type === "player-formats") {
    void fluxRuntimeSend({ type: "media.playerFormats", formats: event.data.formats });
  }
}

document.addEventListener("click", onDocumentClick);

window.addEventListener("message", onPageMessage);

try {
  performanceObserver = new PerformanceObserver((list) => {
    if (!fluxExtensionAlive()) {
      fluxOrphaned();
      return;
    }
    for (const entry of list.getEntries()) {
      if (fluxLooksLikeMedia(entry.name)) {
        void fluxRuntimeSend({ type: "media.observed", url: entry.name });
      }
    }
  });
  performanceObserver.observe({ type: "resource", buffered: true });
} catch {
  // ignore
}

mutation = new MutationObserver(() => scheduleRefresh());
mutation.observe(document.documentElement, { childList: true, subtree: true });
window.addEventListener("scroll", syncOverlays, true);
window.addEventListener("resize", syncOverlays);
refresh();
