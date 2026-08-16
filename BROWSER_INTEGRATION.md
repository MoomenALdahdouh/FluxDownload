# Browser integration

Chrome is implemented. Safari is not.

## Chrome

Load `Extensions/Chrome` as an unpacked extension in `chrome://extensions`.

Do not put `.pem` files in that folder. Chrome treats a private key in the extension directory as an error. The signing material lives in `Extensions/signing/` (gitignored `*.pem`). The public key in `manifest.json` is what keeps the ID stable.

Stable extension ID (from the packed public key): `cdhmompibjahkccghpbepifodgcallpi`

Native messaging host name: `com.fluxdownload.native`

On launch, FluxDownload writes:

`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.fluxdownload.native.json`

pointing at `FluxDownload.app/Contents/MacOS/FluxDownloadNativeHost` when packaged, or the sibling debug binary during `swift run`.

Protocol: Chrome native messaging (32-bit native-endian length + UTF-8 JSON). The host forwards to a `0600` Unix socket after attaching the IPC token.

Allowlisted commands: `ping`, `download.request`, `download.capture`, `media.detected`, `status.query`, `settings.get`.

## Capture

`blob:`, `file:`, `data:`, and `chrome:` URLs are ignored. YouTube and most HTML5 players feed `blob:` / MSE into the element; the extension instead captures the underlying `googlevideo` / media HTTP requests and shows those as formats. DRM-encrypted responses are not offered.

## Safari

NOT IMPLEMENTED — BLOCKED BY VERIFIED PLATFORM LIMITATION: Xcode is not installed; Safari Web Extensions cannot be packaged with SPM alone. See `Extensions/Safari/README.md`.
