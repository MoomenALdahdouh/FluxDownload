function fluxIsHttp(url) {
  return typeof url === "string" && (url.startsWith("http://") || url.startsWith("https://"));
}

function fluxExt(url) {
  try {
    const path = new URL(url, typeof location !== "undefined" ? location.href : undefined).pathname.toLowerCase();
    const match = path.match(/\.([a-z0-9]{2,5})(?:$|[/?])/);
    return match ? match[1] : "";
  } catch {
    return "";
  }
}

function fluxQualityFromURL(url) {
  const text = url.toLowerCase();
  const named = [
    ["2160", 2160],
    ["1440", 1440],
    ["1080", 1080],
    ["720", 720],
    ["480", 480],
    ["360", 360],
    ["240", 240],
    ["144", 144]
  ];
  for (const [token, height] of named) {
    if (new RegExp(`(^|[^0-9])${token}p?([^0-9]|$)`).test(text)) {
      return { height, label: `${height}p` };
    }
  }
  return { height: null, label: null };
}

function fluxContainer(url, mime) {
  const ext = fluxExt(url);
  const type = (mime || "").toLowerCase();
  if (type.includes("webm")) return "WebM";
  if (type.includes("mp4") || type.includes("m4a") || type.includes("m4v")) {
    return type.startsWith("audio/") ? "M4A" : "MP4";
  }
  if (["mp4", "m4v", "mov"].includes(ext)) return "MP4";
  if (ext === "webm") return "WebM";
  if (ext === "mkv") return "MKV";
  if (["m3u8", "m3u"].includes(ext)) return "HLS";
  if (ext === "mpd") return "DASH";
  if (["mp3", "m4a", "aac"].includes(ext)) return ext.toUpperCase();
  if (type.includes("mpegurl")) return "HLS";
  if (type.includes("dash")) return "DASH";
  if (type.startsWith("audio/mpeg")) return "MP3";
  if (type.startsWith("audio/")) return "Audio";
  return ext ? ext.toUpperCase() : "Media";
}

function fluxIsJunkURL(url) {
  const text = url.toLowerCase();
  if (/\.(js|css|woff2?|ttf|png|jpe?g|gif|webp|svg|ico|map)(\?|$)/.test(text)) return true;
  if (text.includes("generate_204") || text.includes("/ptracking") || text.includes("/api/stats")) return true;
  if (text.includes("doubleclick") || text.includes("google-analytics") || text.includes("/pagead/")) return true;
  if (text.includes("play.google.com/log") || text.includes("/youtubei/v1/log")) return true;
  return false;
}

function fluxHasMediaExtension(url) {
  const ext = fluxExt(url);
  return ["mp4", "m4v", "webm", "mov", "mkv", "m3u8", "mpd", "mp3", "m4a", "aac", "ogg", "wav", "flac", "opus"].includes(ext);
}

function fluxIsMediaURL(url, mime) {
  if (!fluxIsHttp(url) || fluxIsJunkURL(url)) return false;
  if (fluxHasMediaExtension(url)) return true;
  if (!mime) return false;
  return mime.startsWith("video/") || mime.startsWith("audio/") || mime.includes("mpegurl") || mime.includes("dash+xml");
}

function fluxIsYouTubeProtocolURL(url) {
  try {
    const parsed = new URL(url);
    if (parsed.searchParams.get("sabr") === "1") return true;
    const host = parsed.hostname.toLowerCase();
    const path = parsed.pathname.toLowerCase();
    if (!(host.includes("googlevideo") || path.includes("videoplayback"))) return false;
    if (!parsed.searchParams.get("itag")) return true;
  } catch {
    // ignore
  }
  return false;
}

function fluxLooksLikeMedia(url, mime) {
  if (!fluxIsHttp(url) || fluxIsJunkURL(url) || fluxIsYouTubeProtocolURL(url)) return false;
  const type = (mime || "").split(";")[0].trim().toLowerCase();
  if (type.includes("yt-ump") || type.includes("vnd.yt")) return false;
  if (fluxIsMediaURL(url, type)) return true;
  if (type.startsWith("video/") || type.startsWith("audio/")) return true;
  if (type.includes("mpegurl") || type.includes("dash+xml")) return true;
  try {
    const parsed = new URL(url);
    const host = parsed.hostname.toLowerCase();
    const path = parsed.pathname.toLowerCase();
    const mimeQuery = (parsed.searchParams.get("mime") || "").toLowerCase().replace("%2f", "/");
    if (mimeQuery.startsWith("video/") || mimeQuery.startsWith("audio/")) return true;
    if (parsed.searchParams.has("itag") && (host.includes("youtube") || host.includes("googlevideo"))) return true;
    if (host.includes("video.twimg.com") || host.includes("vimeocdn.com")) return true;
    if (host.includes("fbcdn.net") && (path.includes(".mp4") || path.includes("/video"))) return true;
    if (path.includes(".m3u8") || path.includes(".mpd")) return true;
    if (/(^|\/)(hls|dash|manifest)(\/|$|\.)/i.test(path)) return true;
  } catch {
    // ignore
  }
  return false;
}

function fluxCanonicalMediaURL(url) {
  try {
    const parsed = new URL(url);
    ["range", "rn", "rbuf", "alr", "keepalive", "bytes"].forEach((key) => parsed.searchParams.delete(key));
    parsed.hash = "";
    return parsed.href;
  } catch {
    return url;
  }
}

function fluxStreamKey(url) {
  try {
    const parsed = new URL(url);
    const itag = parsed.searchParams.get("itag");
    if (itag && (parsed.hostname.includes("googlevideo") || parsed.pathname.includes("videoplayback"))) {
      return `yt:${itag}:${(parsed.searchParams.get("mime") || "").toLowerCase()}`;
    }
    return `${parsed.origin}${parsed.pathname}:${parsed.searchParams.get("id") || ""}:${itag || ""}`;
  } catch {
    return url;
  }
}

const FLUX_YOUTUBE_ITAG = {
  18: { height: 360, container: "MP4", hasVideo: true, hasAudio: true, label: "360p" },
  22: { height: 720, container: "MP4", hasVideo: true, hasAudio: true, label: "720p" },
  37: { height: 1080, container: "MP4", hasVideo: true, hasAudio: true, label: "1080p" },
  133: { height: 240, container: "MP4", hasVideo: true, hasAudio: false },
  134: { height: 360, container: "MP4", hasVideo: true, hasAudio: false },
  135: { height: 480, container: "MP4", hasVideo: true, hasAudio: false },
  136: { height: 720, container: "MP4", hasVideo: true, hasAudio: false },
  137: { height: 1080, container: "MP4", hasVideo: true, hasAudio: false },
  160: { height: 144, container: "MP4", hasVideo: true, hasAudio: false },
  242: { height: 240, container: "WebM", hasVideo: true, hasAudio: false },
  243: { height: 360, container: "WebM", hasVideo: true, hasAudio: false },
  244: { height: 480, container: "WebM", hasVideo: true, hasAudio: false },
  247: { height: 720, container: "WebM", hasVideo: true, hasAudio: false },
  248: { height: 1080, container: "WebM", hasVideo: true, hasAudio: false },
  271: { height: 1440, container: "WebM", hasVideo: true, hasAudio: false },
  278: { height: 144, container: "WebM", hasVideo: true, hasAudio: false },
  313: { height: 2160, container: "WebM", hasVideo: true, hasAudio: false },
  298: { height: 720, container: "MP4", hasVideo: true, hasAudio: false, fps: 60 },
  299: { height: 1080, container: "MP4", hasVideo: true, hasAudio: false, fps: 60 },
  302: { height: 720, container: "WebM", hasVideo: true, hasAudio: false, fps: 60 },
  303: { height: 1080, container: "WebM", hasVideo: true, hasAudio: false, fps: 60 },
  308: { height: 1440, container: "WebM", hasVideo: true, hasAudio: false, fps: 60 },
  315: { height: 2160, container: "WebM", hasVideo: true, hasAudio: false, fps: 60 },
  398: { height: 720, container: "MP4", hasVideo: true, hasAudio: false },
  399: { height: 1080, container: "MP4", hasVideo: true, hasAudio: false },
  400: { height: 1440, container: "MP4", hasVideo: true, hasAudio: false },
  401: { height: 2160, container: "MP4", hasVideo: true, hasAudio: false },
  139: { height: null, container: "M4A", hasVideo: false, hasAudio: true, label: "Audio 48kbps" },
  140: { height: null, container: "M4A", hasVideo: false, hasAudio: true, label: "Audio 128kbps" },
  141: { height: null, container: "M4A", hasVideo: false, hasAudio: true, label: "Audio 256kbps" },
  249: { height: null, container: "WebM", hasVideo: false, hasAudio: true, label: "Audio 50kbps" },
  250: { height: null, container: "WebM", hasVideo: false, hasAudio: true, label: "Audio 70kbps" },
  251: { height: null, container: "WebM", hasVideo: false, hasAudio: true, label: "Audio 160kbps" },
  599: { height: null, container: "M4A", hasVideo: false, hasAudio: true, label: "Audio" },
  600: { height: null, container: "WebM", hasVideo: false, hasAudio: true, label: "Audio" }
};

function fluxYouTubeItag(url) {
  try {
    const itag = Number(new URL(url).searchParams.get("itag"));
    return Number.isFinite(itag) ? itag : null;
  } catch {
    return null;
  }
}

function fluxFormatFromURL(url, mime, extras = {}) {
  const itag = fluxYouTubeItag(url);
  const known = itag ? FLUX_YOUTUBE_ITAG[itag] : null;
  const quality = fluxQualityFromURL(url);
  const type = (mime || extras.mimeType || "").toLowerCase();
  const mimeQuery = (() => {
    try {
      return (new URL(url).searchParams.get("mime") || "").toLowerCase().replace("%2f", "/");
    } catch {
      return "";
    }
  })();
  const audioOnly =
    Boolean(known && known.hasAudio && !known.hasVideo) ||
    type.startsWith("audio/") ||
    mimeQuery.startsWith("audio/") ||
    ["mp3", "m4a", "aac", "ogg", "wav", "flac", "opus"].includes(fluxExt(url));
  const videoOnly = Boolean(known && known.hasVideo && !known.hasAudio);
  const hasAudio = extras.hasAudio ?? (known ? known.hasAudio : !videoOnly);
  const hasVideo = extras.hasVideo ?? (known ? known.hasVideo : !audioOnly);
  const height = extras.height || known?.height || quality.height;
  const fps = extras.fps || known?.fps;
  const container = extras.container || known?.container || fluxContainer(url, type || mimeQuery);
  let label = extras.label || known?.label || quality.label;
  if (!label) {
    if (audioOnly) label = "Audio";
    else if (height) label = `${height}p`;
    else label = "Original";
  }
  if (fps && !label.includes("60")) label = `${label} 60fps`;
  if (hasVideo && !hasAudio && !/video only/i.test(label)) label = `${label} (video only)`;
  return {
    id: extras.id || fluxStreamKey(url),
    url: fluxCanonicalMediaURL(url),
    height,
    label,
    container,
    hasAudio,
    hasVideo,
    mimeType: mime || extras.mimeType || mimeQuery || null,
    protected: Boolean(extras.protected),
    size: extras.size || extras.contentLength || null
  };
}

function fluxParseHLS(text, baseURL) {
  const lines = text.split(/\r?\n/).map((line) => line.trim());
  if (!lines[0]?.startsWith("#EXTM3U")) return { protected: false, formats: [] };
  let protectedMedia = false;
  let pending = null;
  const formats = [];
  for (const line of lines) {
    if (line.startsWith("#EXT-X-KEY") || line.startsWith("#EXT-X-SESSION-KEY")) {
      const method = /METHOD=([^,]+)/.exec(line)?.[1] || "";
      if (/SAMPLE-AES|FAIRPLAY|SAMPLE-AES-CTR/i.test(method)) protectedMedia = true;
    }
    if (line.startsWith("#EXT-X-STREAM-INF")) {
      pending = line;
      continue;
    }
    if (!line || line.startsWith("#")) continue;
    const url = new URL(line, baseURL).href;
    const height = Number(/RESOLUTION=\d+x(\d+)/.exec(pending || "")?.[1] || "") || null;
    const codecs = /CODECS="([^"]+)"/.exec(pending || "")?.[1] || "";
    formats.push(
      fluxFormatFromURL(url, "application/vnd.apple.mpegurl", {
        height,
        label: height ? `${height}p` : "Variant",
        hasAudio: true,
        hasVideo: Boolean(height) || codecs.includes("avc") || codecs.includes("hvc")
      })
    );
    pending = null;
  }
  return { protected: protectedMedia, formats };
}

async function fluxExpandHLS(url) {
  try {
    const response = await fetch(url, { credentials: "include" });
    if (!response.ok) return [];
    const text = await response.text();
    const parsed = fluxParseHLS(text, url);
    if (parsed.protected) {
      return parsed.formats.map((format) => ({ ...format, protected: true }));
    }
    return parsed.formats.length ? parsed.formats : [fluxFormatFromURL(url, "application/vnd.apple.mpegurl")];
  } catch {
    return [fluxFormatFromURL(url, "application/vnd.apple.mpegurl")];
  }
}

function fluxMergeFormats(formats) {
  const seen = new Map();
  for (const format of formats) {
    if (!format?.url || format.protected) continue;
    const key = fluxStreamKey(format.url);
    const previous = seen.get(key);
    if (!previous || (format.height || 0) > (previous.height || 0)) {
      seen.set(key, format);
    }
  }
  return [...seen.values()].sort((a, b) => {
    const bothA = a.hasVideo && a.hasAudio ? 1 : 0;
    const bothB = b.hasVideo && b.hasAudio ? 1 : 0;
    if (bothA !== bothB) return bothB - bothA;
    if (Boolean(a.hasVideo) !== Boolean(b.hasVideo)) return a.hasVideo ? -1 : 1;
    return (b.height || 0) - (a.height || 0);
  });
}

function fluxBestAudio(formats) {
  return formats.find((format) => format.hasAudio && !format.hasVideo) || null;
}

function fluxExtractJSONObject(text, marker) {
  const start = text.indexOf(marker);
  if (start < 0) return null;
  const brace = text.indexOf("{", start);
  if (brace < 0) return null;
  let depth = 0;
  for (let index = brace; index < text.length && index - brace < 4_000_000; index += 1) {
    const char = text[index];
    if (char === "{") depth += 1;
    else if (char === "}") {
      depth -= 1;
      if (depth === 0) {
        try {
          return JSON.parse(text.slice(brace, index + 1));
        } catch {
          return null;
        }
      }
    }
  }
  return null;
}

function fluxFormatsFromStreamingData(data) {
  if (!data) return [];
  const formats = [];
  const push = (row, progressive) => {
    const url = row.url;
    if (!fluxIsHttp(url)) return;
    const mime = row.mimeType || "";
    const audioOnly = mime.toLowerCase().startsWith("audio/");
    formats.push(
      fluxFormatFromURL(url, mime, {
        height: row.height || null,
        label: row.qualityLabel || null,
        hasAudio: progressive || audioOnly || Boolean(row.audioQuality),
        hasVideo: progressive ? !audioOnly : Boolean(row.width || row.height || mime.toLowerCase().startsWith("video/")),
        size: row.contentLength ? Number(row.contentLength) : null,
        fps: row.fps
      })
    );
  };
  (data.formats || []).forEach((row) => push(row, true));
  (data.adaptiveFormats || []).forEach((row) => push(row, false));
  return formats;
}

function fluxExtractPageStreamingFormats() {
  const formats = [];
  try {
    for (const script of document.scripts) {
      const text = script.textContent || "";
      if (text.includes("ytInitialPlayerResponse")) {
        const parsed = fluxExtractJSONObject(text, "ytInitialPlayerResponse");
        formats.push(...fluxFormatsFromStreamingData(parsed?.streamingData));
      }
      if (text.includes("player_response")) {
        const nested = /player_response["']?\s*[:=]\s*["'](.+?)["']/.exec(text);
        if (nested?.[1]) {
          try {
            const inner = JSON.parse(nested[1].replace(/\\"/g, '"'));
            formats.push(...fluxFormatsFromStreamingData(inner?.streamingData));
          } catch {
            // ignore
          }
        }
      }
    }
    document.querySelectorAll('meta[property="og:video"], meta[property="og:video:url"], meta[property="og:audio"], meta[itemprop="contentUrl"]').forEach((node) => {
      const url = node.getAttribute("content");
      if (fluxLooksLikeMedia(url)) formats.push(fluxFormatFromURL(url, ""));
    });
  } catch {
    // ignore
  }
  return fluxMergeFormats(formats);
}

function fluxPageTitle() {
  try {
    let title = document.title || "media";
    title = title.replace(/\s*-\s*YouTube\s*$/i, "").replace(/\s*\|\s*Vimeo\s*$/i, "");
    title = title.replace(/[<>:"/\\|?*]/g, " ").replace(/\s+/g, " ").trim();
    return title.slice(0, 80) || "media";
  } catch {
    return "media";
  }
}

function fluxFilename(url, format) {
  const title = typeof document !== "undefined" ? fluxPageTitle() : "media";
  const ext = (format?.container || fluxContainer(url, format?.mimeType) || "mp4").toLowerCase();
  const safeExt = ["mp4", "m4a", "webm", "mkv", "mp3", "aac", "mov", "hls"].includes(ext) ? (ext === "hls" ? "m3u8" : ext) : "mp4";
  if (format?.hasVideo === false && format?.hasAudio) {
    return `${title}-audio.${safeExt === "mp4" ? "m4a" : safeExt}`;
  }
  const suffix = format?.height ? `-${format.height}p` : "";
  try {
    const name = decodeURIComponent(new URL(url).pathname.split("/").pop() || "");
    if (name && name.includes(".") && !name.startsWith("videoplayback")) {
      return name.split("?")[0];
    }
  } catch {
    // ignore
  }
  return `${title}${suffix}.${safeExt}`;
}

function fluxYouTubeVideoId(url) {
  try {
    const parsed = new URL(url);
    const host = parsed.hostname.replace(/^www\./, "").toLowerCase();
    if (host === "youtu.be") return parsed.pathname.split("/").filter(Boolean)[0] || null;
    if (host.endsWith("youtube.com") || host.endsWith("youtube-nocookie.com")) {
      if (parsed.searchParams.get("v")) return parsed.searchParams.get("v");
      const parts = parsed.pathname.split("/").filter(Boolean);
      if (["shorts", "embed", "live", "v"].includes(parts[0])) return parts[1] || null;
    }
  } catch {
    // ignore
  }
  return null;
}

const FLUX_YT_PLAYER_CLIENTS = [
  {
    clientName: "ANDROID",
    clientVersion: "20.10.38",
    userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip",
    extra: { androidSdkVersion: 34, osName: "Android", osVersion: "14" }
  },
  {
    clientName: "IOS",
    clientVersion: "20.10.4",
    userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X)",
    extra: { deviceMake: "Apple", deviceModel: "iPhone16,2", osName: "iPhone", osVersion: "18.3.2.22D82" }
  },
  {
    clientName: "ANDROID_VR",
    clientVersion: "1.60.19",
    userAgent: "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12; en_US) gzip",
    extra: { deviceMake: "Oculus", deviceModel: "Quest 3", androidSdkVersion: 32 }
  }
];

async function fluxResolveYouTubePlayer(videoId) {
  if (!videoId || !/^[a-zA-Z0-9_-]{11}$/.test(videoId)) {
    return { ok: false, reason: "bad-video-id" };
  }
  for (const client of FLUX_YT_PLAYER_CLIENTS) {
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 8000);
      const res = await fetch("https://www.youtube.com/youtubei/v1/player?prettyPrint=false", {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          context: {
            client: {
              clientName: client.clientName,
              clientVersion: client.clientVersion,
              hl: "en",
              gl: "US",
              utcOffsetMinutes: 0,
              ...client.extra
            }
          },
          videoId,
          contentCheckOk: true,
          racyCheckOk: true
        }),
        signal: controller.signal
      });
      clearTimeout(timer);
      const json = await res.json();
      const formats = [...(json.streamingData?.formats || []), ...(json.streamingData?.adaptiveFormats || [])];
      const withUrl = formats.filter((row) => typeof row.url === "string" && row.url.indexOf("http") === 0);
      const pick =
        withUrl.find((row) => Number(row.itag) === 18) ||
        withUrl.find((row) => /video\/mp4/i.test(row.mimeType || "") && (row.audioQuality || row.audioSampleRate)) ||
        withUrl.find((row) => /video\/mp4/i.test(row.mimeType || ""));
      if (pick && pick.url) {
        return {
          ok: true,
          url: pick.url,
          mimeType: pick.mimeType || "video/mp4",
          itag: pick.itag,
          userAgent: client.userAgent,
          client: client.clientName
        };
      }
    } catch {
      // try the next client
    }
  }
  return { ok: false, reason: "no-direct-url" };
}
