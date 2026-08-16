const HOST = "com.fluxdownload.native";
importScripts("media-detect.js");

const tabMedia = new Map();

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: "download-page", title: "Download with FluxDownload", contexts: ["page"] });
    chrome.contextMenus.create({ id: "download-link", title: "Download link with FluxDownload", contexts: ["link"] });
    chrome.contextMenus.create({ id: "download-image", title: "Download image with FluxDownload", contexts: ["image"] });
    chrome.contextMenus.create({ id: "download-video", title: "Download video with FluxDownload", contexts: ["video", "audio"] });
    chrome.contextMenus.create({ id: "download-selection", title: "Download selected links", contexts: ["selection"] });
    chrome.contextMenus.create({ id: "add-queue", title: "Add to FluxDownload queue", contexts: ["link"] });
  });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const pageURL = tab?.url || "";
  if (info.menuItemId === "download-selection" && info.selectionText) {
    const urls = info.selectionText.match(/https?:\/\/[^\s]+/g) || [];
    for (const url of urls) {
      await sendDownload(url, pageURL, null, false);
    }
    return;
  }
  const url = info.linkUrl || info.srcUrl || pageURL;
  if (url && !url.startsWith("blob:")) await sendDownload(url, pageURL, info.mediaType || null, false);
});

chrome.downloads.onCreated.addListener(async (item) => {
  const enabled = (await chrome.storage.local.get({ capture: true })).capture;
  if (!enabled) return;
  if (!item.url || item.url.startsWith("blob:") || item.url.startsWith("file:") || item.url.startsWith("data:") || item.url.startsWith("chrome")) {
    return;
  }
  try {
    await chrome.downloads.pause(item.id);
  } catch (_) {
    return;
  }
  const result = await sendDownload(item.url, item.referrer || "", item.filename, true, item.mime, item.fileSize, String(item.id));
  if (result && result.ok) {
    try { await chrome.downloads.cancel(item.id); } catch (_) {}
  } else {
    try { await chrome.downloads.resume(item.id); } catch (_) {}
  }
});

chrome.webRequest.onHeadersReceived.addListener(
  (details) => {
    rememberRequest(details);
  },
  { urls: ["http://*/*", "https://*/*"] },
  ["responseHeaders"]
);

chrome.webNavigation.onCommitted.addListener((details) => {
  if (details.frameId === 0) resetTabIfPageChanged(details.tabId, details.url);
});

chrome.webNavigation.onHistoryStateUpdated.addListener((details) => {
  if (details.frameId === 0) resetTabIfPageChanged(details.tabId, details.url);
});

chrome.tabs.onRemoved.addListener((tabId) => {
  tabMedia.delete(tabId);
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === "media.download") {
    sendDownload(
      message.url,
      sender.tab?.url || message.pageURL || "",
      message.filename || null,
      false,
      message.mimeType,
      null,
      null,
      sender.tab?.id,
      true,
      message.segmentURLs
    )
      .then(async (primary) => {
        if (primary?.ok && message.audioURL) {
          await sendDownload(
            message.audioURL,
            sender.tab?.url || "",
            message.audioFilename || null,
            false,
            message.audioMimeType || "audio/mp4",
            null,
            null,
            sender.tab?.id,
            false
          );
        }
        sendResponse(primary);
      });
    return true;
  }
  if (message?.type === "media.observed") {
    rememberURL(sender.tab?.id, message.url, message.mimeType || "", sender.tab?.url);
    sendResponse({ ok: true });
    return false;
  }
  if (message?.type === "media.playerFormats") {
    const tabId = sender.tab?.id;
    for (const row of message.formats || []) {
      rememberURL(tabId, row.url, row.mimeType || "", sender.tab?.url, row);
    }
    sendResponse({ ok: true });
    return false;
  }
  if (message?.type === "media.forTab") {
    const tabId = sender.tab?.id ?? message.tabId;
    sendResponse({ formats: formatsForTab(tabId) });
    return false;
  }
  if (message?.type === "status") {
    ping().then(async (response) => {
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      let formats = formatsForTab(tab?.id);
      const videoId = fluxYouTubeVideoId(tab?.url || "");
      if (videoId) {
        try {
          const resolved = await fluxResolveYouTubePlayer(videoId);
          if (resolved?.ok && resolved.formats?.length) {
            formats = fluxPresentYouTubeQualities(fluxMergeFormats([...formats, ...resolved.formats]));
          }
        } catch {
          // keep sniffed formats
        }
      }
      sendResponse({ ...response, formats });
    });
    return true;
  }
  if (message?.type === "setCapture") {
    chrome.storage.local.set({ capture: !!message.value }).then(() => sendResponse({ ok: true }));
    return true;
  }
});

function pageIdentity(url) {
  try {
    const parsed = new URL(url);
    if (parsed.hostname.includes("youtube")) return parsed.searchParams.get("v") || parsed.pathname;
    return `${parsed.origin}${parsed.pathname}`;
  } catch {
    return url || "";
  }
}

function resetTabIfPageChanged(tabId, url) {
  if (!tabId || tabId < 0) return;
  const key = pageIdentity(url);
  const current = tabMedia.get(tabId);
  if (current && current.pageKey && key && current.pageKey !== key) {
    tabMedia.set(tabId, { pageKey: key, streams: new Map() });
  } else if (!current) {
    tabMedia.set(tabId, { pageKey: key, streams: new Map() });
  } else if (key) {
    current.pageKey = key;
  }
}

function headerValue(headers, name) {
  const hit = (headers || []).find((header) => header.name.toLowerCase() === name.toLowerCase());
  return hit?.value || "";
}

function rememberRequest(details) {
  if (!details || details.tabId < 0) return;
  const mime = headerValue(details.responseHeaders, "content-type").split(";")[0].trim();
  rememberURL(details.tabId, details.url, mime, details.initiator || details.documentUrl, {
    size: Number(headerValue(details.responseHeaders, "content-length") || "") || null
  });
}

function rememberURL(tabId, url, mime, pageURL, extras = {}) {
  if (!tabId || tabId < 0) return;
  const type = (mime || "").toLowerCase();
  if (type.includes("yt-ump") || type.includes("application/vnd.yt") || fluxIsYouTubeProtocolURL(url)) return;
  if (!fluxLooksLikeMedia(url, mime)) return;
  const canonical = fluxCanonicalMediaURL(url);
  const entry = tabMedia.get(tabId) || { pageKey: pageIdentity(pageURL), streams: new Map() };
  if (pageURL) {
    const key = pageIdentity(pageURL);
    if (entry.pageKey && key && entry.pageKey !== key) {
      entry.streams = new Map();
    }
    entry.pageKey = key || entry.pageKey;
  }
  const format = fluxFormatFromURL(canonical, mime, extras);
  const key = fluxStreamKey(canonical);
  const previous = entry.streams.get(key);
  if (previous) {
    format.segmentURLs = fluxStableMediaURLs([
      ...(previous.segmentURLs || []),
      previous.url,
      format.url,
      canonical
    ]);
    format.url = format.segmentURLs[0] || format.url;
    if ((previous.height || 0) > (format.height || 0)) {
      format.height = previous.height;
      format.label = previous.label || format.label;
    }
  } else {
    format.segmentURLs = fluxStableMediaURLs([canonical]);
  }
  entry.streams.set(key, format);
  tabMedia.set(tabId, entry);
}

function formatsForTab(tabId) {
  if (!tabId) return [];
  const entry = tabMedia.get(tabId);
  return entry ? fluxMergeFormats([...entry.streams.values()]) : [];
}

async function cookieHeaderFor(url, pageURL) {
  const names = new Map();
  for (const target of [url, pageURL].filter(Boolean)) {
    try {
      const list = await chrome.cookies.getAll({ url: target });
      for (const cookie of list) names.set(cookie.name, cookie.value);
    } catch {
      // ignore
    }
  }
  const preferred = ["SID", "HSID", "SSID", "APISID", "SAPISID", "__Secure-1PSID", "__Secure-3PSID", "LOGIN_INFO", "PREF", "VISITOR_INFO1_LIVE", "YSC", "SIDCC"];
  const ordered = [
    ...preferred.filter((name) => names.has(name)).map((name) => [name, names.get(name)]),
    ...[...names.entries()].filter(([name]) => !preferred.includes(name))
  ];
  let header = ordered.map(([name, value]) => `${name}=${value}`).join("; ");
  if (header.length > 16_000) {
    header = preferred.filter((name) => names.has(name)).map((name) => `${name}=${names.get(name)}`).join("; ");
  }
  if (!header || header.length > 16_000) return null;
  return header;
}

async function resolveYouTubeDownload(pageURL, tabId) {
  const videoId = fluxYouTubeVideoId(pageURL);
  if (!videoId) return { ok: false, reason: "no-video-id" };
  if (tabId) {
    try {
      await chrome.scripting.executeScript({
        target: { tabId },
        world: "MAIN",
        files: ["media-detect.js"]
      });
      const [injected] = await chrome.scripting.executeScript({
        target: { tabId },
        world: "MAIN",
        func: (id) => fluxResolveYouTubePlayer(id),
        args: [videoId]
      });
      if (injected?.result?.ok) return injected.result;
      const fallback = await fluxResolveYouTubePlayer(videoId);
      if (fallback.ok) return fallback;
      return injected?.result || fallback;
    } catch {
      return fluxResolveYouTubePlayer(videoId);
    }
  }
  return fluxResolveYouTubePlayer(videoId);
}

async function sendDownload(url, pageURL, filename, capture, mimeType, fileSize, browserRequestId, tabId, openStatusWindow = true, segmentURLs = null) {
  if (!url || url.startsWith("blob:") || url.startsWith("file:") || url.startsWith("data:")) {
    return { ok: false, error: "This media has no HTTP file URL yet. Play it, then try again." };
  }
  if (!pageURL || !tabId) {
    try {
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      pageURL = pageURL || tab?.url || "";
      tabId = tabId || tab?.id;
    } catch {
      // ignore
    }
  }
  if (fluxIsYouTubeProtocolURL(url)) {
    return { ok: false, error: "This is a YouTube player stream, not a downloadable file. Choose a listed MP4/WebM format." };
  }
  let downloadURL = url;
  let downloadMime = mimeType || null;
  let downloadUA = navigator.userAgent;
  let downloadReferrer = pageURL || null;
  let downloadCookies = await cookieHeaderFor(url, pageURL);
  let downloadHeaders = {};
  try {
    const downloadHost = new URL(url).hostname.toLowerCase();
    const skipOrigin = downloadHost.includes("licdn.com") || downloadHost.includes("googlevideo") || downloadHost.includes("youtube.com");
    const origin = pageURL ? new URL(pageURL).origin : new URL(url).origin;
    if (origin && !skipOrigin) downloadHeaders = { Origin: origin };
    if (downloadHost.includes("licdn.com")) {
      downloadCookies = null;
      const segments = fluxStableMediaURLs([...(segmentURLs || []), url]);
      if (segments[0]) downloadURL = segments[0];
      if (segments.length) downloadHeaders = { ...downloadHeaders, "X-Flux-Segment-URLs": JSON.stringify(segments.slice(0, 400)) };
    }
  } catch {
    // ignore
  }
  const videoId = fluxYouTubeVideoId(pageURL) || fluxYouTubeVideoId(url);
  if (videoId) {
    const resolvedTab = tabId || (await chrome.tabs.query({ active: true, currentWindow: true }))[0]?.id;
    const resolved = await resolveYouTubeDownload(pageURL || url, resolvedTab);
    if (resolved?.ok) {
      const picked = fluxPickYouTubeFormat(resolved, url, downloadMime);
      if (picked?.url) {
        downloadURL = picked.url;
        downloadMime = picked.mimeType || downloadMime;
        downloadUA = resolved.userAgent || downloadUA;
        downloadReferrer = null;
        downloadCookies = null;
        downloadHeaders = {};
      }
    }
  }
  const payload = {
    version: 1,
    type: capture ? "download.capture" : "download.request",
    id: crypto.randomUUID(),
    payload: {
      url: downloadURL,
      pageURL,
      referrer: downloadReferrer,
      filename,
      mimeType: downloadMime,
      source: "chrome",
      browserRequestId: browserRequestId || null,
      fileSize: fileSize || null,
      capture: !!capture,
      cookies: downloadCookies,
      userAgent: downloadUA,
      headers: downloadHeaders,
      openStatusWindow: openStatusWindow !== false
    }
  };
  try {
    const result = await chrome.runtime.sendNativeMessage(HOST, payload);
    return result;
  } catch (error) {
    return { ok: false, error: "Desktop app is not connected." };
  }
}

async function ping() {
  try {
    const response = await chrome.runtime.sendNativeMessage(HOST, {
      version: 1,
      type: "ping",
      id: crypto.randomUUID(),
      payload: {}
    });
    return response;
  } catch (_) {
    return { ok: false, connected: false, error: "Not connected" };
  }
}
