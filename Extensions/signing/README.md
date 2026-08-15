Chrome extension signing files. Keep `chrome.pem` out of `Extensions/Chrome`.

Chrome warns and refuses a clean load if a `.pem` is inside the unpacked extension directory. `manifest.json` already contains the matching public `key`, which is enough for the stable ID `cdhmompibjahkccghpbepifodgcallpi`.
