// Any other site, by the person's choice (toolbar button).
importScripts("site-access.js");

// Safari relay: content scripts cannot reach the native handler, so the background script
// asks it for each next frame and forwards the frame over a runtime port. Frames come only
// from the local Locked Gaze app; the page sends nothing but "start" and "stop".
const APP = "local.lockedgaze.app";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Each native request waits for the first frame newer than its `after`. A single request
// in flight would cap the frame rate at one frame per round trip, so several are kept in
// flight, each asking for the next frame number.
const IN_FLIGHT = 6;

browser.runtime.onConnect.addListener((page) => {
  if (page.name !== "relay") return;
  let open = true, started = false, nextAfter = 0, delivered = 0, failures = 0, requests = 0, erroring = false;
  page.onDisconnect.addListener(() => { open = false; });
  page.onMessage.addListener((message) => {
    if (message.cmd === "start" && !started) { started = true; for (let i = 0; i < IN_FLIGHT; i++) worker(); }
    if (message.cmd === "stop") open = false;
  });
  const post = (message) => { try { page.postMessage(message); return true; } catch { open = false; return false; } };

  async function worker() {
    while (open) {
      // Workers ask for consecutive frame numbers: after N, N+1, N+2, …
      const after = nextAfter++;
      let response;
      requests++;
      try { response = await browser.runtime.sendNativeMessage(APP, { cmd: "frame", after }); failures = 0; }
      catch (error) {
        // Safari can fail a single request, for example while it relaunches the handler.
        failures++;
        response = failures < 4 * IN_FLIGHT ? null
          : { error: "Locked Gaze is not available", detail: `${error?.message || error} (after ${requests} requests)` };
      }
      if (!open) break;
      if (response?.jpeg) {
        erroring = false;
        // Workers finish out of order: drop anything older than what the page already has.
        if (response.seq > delivered) {
          delivered = response.seq;
          response.tsw = Date.now();
          if (!post(response)) break;
        }
        nextAfter = Math.max(nextAfter, delivered);
      } else if (response?.error) {
        // While Locked Gaze is unavailable, one worker reports and all slow down.
        if (!erroring) { erroring = true; post({ error: response.error, detail: response.detail }); }
        nextAfter = delivered;
        await sleep(500);
      } else if (!response) {
        await sleep(50);
      }
    }
  }
});
