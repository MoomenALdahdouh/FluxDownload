# Video detection

The Chrome extension captures media the same way a Windows download accelerator does: it watches real HTTP(S) requests, not the `blob:` URL on the `<video>` tag.

Sources, in order:

1. `chrome.webRequest` response headers (`video/*`, `audio/*`, HLS, DASH, `videoplayback`, `googlevideo`, and similar hosts)
2. Page `fetch` / `XMLHttpRequest` URLs
3. `ytInitialPlayerResponse.streamingData` entries that already include a complete `https` URL (no signature deciphering)
4. `<video>` / `<audio>` `src` and HLS playlists when the page publishes them

EME / `mediaKeys`, FairPlay-style HLS keys, and DASH `ContentProtection` stay rejected. AES-128 HLS with a fetchable `http(s)` key is ordinary HTTP, not DRM.

YouTube adaptive qualities are often video-only. Choosing one also queues the best captured audio file. Progressive 360p/720p rows include audio in a single file when YouTube still publishes them.

Play the media once if the overlay says it is waiting — the player must request the stream before a file URL exists.
