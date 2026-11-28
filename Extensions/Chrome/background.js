// Any other site, by the person's choice (toolbar button).
importScripts("site-access.js");

// Chrome relay: the service worker owns the Native Messaging port to the Locked Gaze helper
// and forwards each frame to the meeting page's content script. Frames come only from the
// local Locked Gaze app; the page sends nothing but "start" and "stop".
const HOST = "local.lockedgaze.browser";

chrome.runtime.onConnect.addListener((page) => {
  if (page.name !== "relay") return;
  const native = chrome.runtime.connectNative(HOST);
  let pageOpen = true;
  native.onMessage.addListener((message) => { if (pageOpen) page.postMessage(message); });
  native.onDisconnect.addListener(() => {
    if (!pageOpen) return;
    page.postMessage({ error: "Open Locked Gaze and choose Set Up Google Chrome", detail: chrome.runtime.lastError?.message });
    page.disconnect();
  });
  page.onMessage.addListener((message) => native.postMessage(message));
  page.onDisconnect.addListener(() => { pageOpen = false; native.disconnect(); });
});
