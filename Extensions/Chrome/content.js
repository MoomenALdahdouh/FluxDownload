const overlayState = new WeakMap();
let openPanel = null;

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
  return new Promise((resolve) => {
    chrome.runtime.sendMessage({ type: "media.forTab" }, (response) => {
      resolve(response?.formats || []);
    });
  });
}

async function formatsForPlayer(media) {
  const httpSources = playerSources(media).filter(fluxIsHttp);
  const nearby = resourceCandidates();
  let local = [];
  for (const url of [...httpSources, ...nearby]) {
    if (fluxExt(url) === "m3u8") {
      local.push(...(await fluxExpandHLS(url)));
    } else if (fluxLooksLikeMedia(url)) {
      const extras = {};
      if (httpSources.includes(url) && media.videoHeight) extras.height = media.videoHeight;
      local.push(fluxFormatFromURL(url, "", extras));
    }
  }
  const sniffed = await requestSniffed();
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
  return new Promise((resolve) => {
    chrome.runtime.sendMessage(
      {
        type: "media.download",
        url: format.url,
        filename: fluxFilename(format.url, format),
        mimeType: format.mimeType,
        audioURL: extras.audio?.url || null,
        audioFilename: extras.audio ? fluxFilename(extras.audio.url, extras.audio) : null,
        audioMimeType: extras.audio?.mimeType || null
      },
      resolve
    );
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
        row.disabled = true;
        row.querySelector(".flux-row-meta").textContent = "Sending to FluxDownload…";
        const extras = format.hasVideo && !format.hasAudio && bestAudio ? { audio: bestAudio } : {};
        const response = await sendFormat(format, extras);
        row.querySelector(".flux-row-meta").textContent = response?.ok
          ? extras.audio
            ? "Sent video + audio to FluxDownload"
            : "Sent to FluxDownload"
          : response?.error || "Desktop app is not connected";
        if (response?.ok) setTimeout(closePanel, 800);
        else row.disabled = false;
      });
      list.append(row);
    });
    panel.append(list);
    const note = document.createElement("p");
    note.className = "flux-note";
    note.textContent = "YouTube qualities come from the video’s available streams. Progressive 360p is one file with audio; higher resolutions send a video file plus a matching audio file.";
    panel.append(note);
  }

  document.documentElement.append(panel);
  openPanel = panel;
  positionPanel(panel, media, anchor);
}

function positionChip(chip, media) {
  const rect = media.getBoundingClientRect();
  const minW = media.tagName === "AUDIO" ? 72 : 120;
  const minH = media.tagName === "AUDIO" ? 18 : 70;
  if (rect.width < minW || rect.height < minH || !media.isConnected) {
    chip.hidden = true;
    return;
  }
  chip.hidden = false;
  const top = window.scrollY + rect.top + 10;
  const left = window.scrollX + rect.right - chip.offsetWidth - 10;
  chip.style.top = `${Math.max(window.scrollY + 8, top)}px`;
  chip.style.left = `${Math.max(window.scrollX + 8, left)}px`;
}

function positionPanel(panel, media, anchor) {
  const rect = (anchor || media).getBoundingClientRect();
  panel.style.top = `${window.scrollY + rect.bottom + 8}px`;
  panel.style.left = `${Math.max(12, window.scrollX + rect.right - 320)}px`;
}

function placeOverlay(media) {
  if (overlayState.has(media)) return overlayState.get(media);
  const chip = document.createElement("button");
  chip.type = "button";
  chip.className = "flux-chip";
  const label = media.tagName === "AUDIO" ? "Audio" : "Download";
  chip.innerHTML = `<span class="flux-chip-mark">↓</span><span>${label}</span>`;
  chip.setAttribute("aria-label", `Download ${label.toLowerCase()} with FluxDownload`);
  document.documentElement.append(chip);

  const sync = () => {
    positionChip(chip, media);
    if (openPanel) positionPanel(openPanel, media, chip);
  };
  sync();
  const observer = new ResizeObserver(sync);
  observer.observe(media);
  window.addEventListener("scroll", sync, true);
  window.addEventListener("resize", sync);

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

  overlayState.set(media, chip);
  return chip;
}

function refresh() {
  document.querySelectorAll("video, audio").forEach((media) => placeOverlay(media));
}

document.addEventListener("click", (event) => {
  if (openPanel && !openPanel.contains(event.target) && !event.target.closest(".flux-chip")) {
    closePanel();
  }
});

window.addEventListener("message", (event) => {
  if (event.source !== window || event.data?.source !== "fluxdownload") return;
  if (event.data.type === "media-url") {
    chrome.runtime.sendMessage({ type: "media.observed", url: event.data.url, mimeType: event.data.mime });
  }
  if (event.data.type === "player-formats") {
    chrome.runtime.sendMessage({ type: "media.playerFormats", formats: event.data.formats });
  }
});

try {
  const observer = new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) {
      if (fluxLooksLikeMedia(entry.name)) {
        chrome.runtime.sendMessage({ type: "media.observed", url: entry.name });
      }
    }
  });
  observer.observe({ type: "resource", buffered: true });
} catch {
  // ignore
}

const mutation = new MutationObserver(() => refresh());
mutation.observe(document.documentElement, { childList: true, subtree: true });
refresh();
