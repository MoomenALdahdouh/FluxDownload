# Troubleshooting

Native host not found
: Start FluxDownload once. Confirm `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.fluxdownload.native.json` exists and `path` is executable.

Extension cannot connect
: Extension ID must be `cdhmompibjahkccghpbepifodgcallpi`. Reload the unpacked extension. The desktop app must be running or the host must be able to launch `FluxDownload.app`.

Downloads do not resume after Quit
: Closing the window is not Quit. After a full Quit, unfinished work is restored on next launch if “Resume unfinished downloads” is on.

Safari missing
: Expected. Xcode is required to package a Safari Web Extension.
