const statusEl = document.getElementById("status");
const captureEl = document.getElementById("capture");
const formatsEl = document.getElementById("formats");

function renderFormats(formats) {
  formatsEl.replaceChildren();
  if (!formats?.length) {
    formatsEl.textContent = "Play a video or audio file, then open this popup.";
    return;
  }
  formats.forEach((format) => {
    const button = document.createElement("button");
    button.className = "format";
    button.textContent = `${format.label} · ${format.container}`;
    button.addEventListener("click", () => {
      button.disabled = true;
      chrome.runtime.sendMessage(
        {
          type: "media.download",
          url: format.url,
          filename: null,
          mimeType: format.mimeType
        },
        (response) => {
          button.textContent = response?.ok ? "Sent to FluxDownload" : response?.error || "Not connected";
          if (!response?.ok) button.disabled = false;
        }
      );
    });
    formatsEl.append(button);
  });
}

function refresh() {
  chrome.runtime.sendMessage({ type: "status" }, (response) => {
    if (response?.ok) {
      statusEl.textContent = `Connected to desktop app ${response.appVersion || ""}`.trim();
    } else {
      statusEl.textContent = response?.error || "Desktop app is not connected.";
    }
    renderFormats(response?.formats || []);
  });
}

chrome.storage.local.get({ capture: true }, (value) => {
  captureEl.checked = value.capture;
});

captureEl.addEventListener("change", () => {
  chrome.runtime.sendMessage({ type: "setCapture", value: captureEl.checked });
});

document.getElementById("open").addEventListener("click", refresh);
refresh();
