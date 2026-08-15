# Release

```bash
Scripts/package-app.sh
Scripts/package-dmg.sh
```

Signing uses `Developer ID Application` when present, otherwise ad-hoc. Ad-hoc builds are **not** notarization-ready and must not be described as a shipping release.

Notarization (when a Developer ID exists):

```bash
xcrun notarytool submit build/FluxDownload.dmg --keychain-profile AC_PASSWORD --wait
xcrun stapler staple build/FluxDownload.dmg
```

Required for Hardened Runtime packaging: `Resources/FluxDownload.entitlements`. Network Extension entitlements are not used.
