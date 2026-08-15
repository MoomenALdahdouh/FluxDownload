NOT IMPLEMENTED — BLOCKED BY VERIFIED PLATFORM LIMITATION

Safari Web Extensions must be packaged as an `.appex` inside a containing macOS app, with native messages handled by `SafariWebExtensionHandler` (`NSExtensionRequestHandling`). That packaging path requires Xcode.

This environment has Apple Command Line Tools only. FluxDownload is built with Swift Package Manager.

Safari will be implemented when Xcode is available. Until then the Settings window reports Safari as unavailable. Do not load anything in this folder as a working Safari extension.
