// Extension-side content script. Opens the frame stream only while the page holds a
// Locked Gaze track and hands each JPEG to the page. Frames flow from the app into the
// browser only; the page sends nothing but "start" and "stop".
(() => {
  const TAG = "__lockedGaze";
  let port = null;

  const decode = Uint8Array.fromBase64
    ? (text) => Uint8Array.fromBase64(text)
    : (text) => { const s = atob(text); const b = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i); return b; };

  const toPage = (message, transfer) => window.postMessage({ [TAG]: "bridge", ...message }, location.origin, transfer);

  function start() {
    if (port) return;
    port = chrome.runtime.connect({ name: "relay" });
    port.onMessage.addListener((message) => {
      if (message.error) return toPage({ type: "error", message: message.error, detail: message.detail });
      if (!message.jpeg) return;
      const jpeg = decode(message.jpeg).buffer;
      toPage({ type: "frame", seq: message.seq, t0: message.t0, jpeg }, [jpeg]);
    });
    port.onDisconnect.addListener(() => { port = null; toPage({ type: "error", message: "Locked Gaze is not running" }); });
    port.postMessage({ cmd: "start", source: "app" });
  }

  function stop() {
    if (!port) return;
    try { port.postMessage({ cmd: "stop" }); port.disconnect(); } catch {}
    port = null;
  }

  window.addEventListener("message", (event) => {
    const data = event.data;
    if (event.source !== window || !data || data[TAG] !== "page") return;
    if (data.type === "start") start();
    if (data.type === "stop") stop();
  });
  window.addEventListener("pagehide", stop);
})();
