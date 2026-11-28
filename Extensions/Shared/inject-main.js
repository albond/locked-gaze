// Runs in the page's own JavaScript world on meeting sites, before the site's scripts.
// Adds "Locked Gaze Camera" to the site's camera list. When the site picks it, the browser
// never opens a physical camera: the video track is drawn from frames that Locked Gaze
// sends one way into the browser. Any other camera choice passes through untouched.
(() => {
  const media = navigator.mediaDevices;
  if (!media || media.__lockedGaze) return;
  Object.defineProperty(media, "__lockedGaze", { value: true });

  const DEVICE_ID = "locked-gaze-camera";
  const GROUP_ID = "locked-gaze";
  const LABEL = "Locked Gaze Camera";
  const WIDTH = 1280, HEIGHT = 720, FPS = 30;
  const TAG = "__lockedGaze";

  const originalGetUserMedia = media.getUserMedia.bind(media);
  const originalEnumerate = media.enumerateDevices.bind(media);

  const capabilities = () => ({
    deviceId: DEVICE_ID, groupId: GROUP_ID, facingMode: [], resizeMode: ["none"],
    width: { min: WIDTH, max: WIDTH }, height: { min: HEIGHT, max: HEIGHT },
    aspectRatio: { min: WIDTH / HEIGHT, max: WIDTH / HEIGHT }, frameRate: { min: 1, max: FPS },
  });
  const deviceInfo = {
    deviceId: DEVICE_ID, groupId: GROUP_ID, kind: "videoinput", label: LABEL,
    getCapabilities: capabilities,
    toJSON() { return { deviceId: DEVICE_ID, groupId: GROUP_ID, kind: "videoinput", label: LABEL }; },
  };
  if (window.InputDeviceInfo) Object.setPrototypeOf(deviceInfo, InputDeviceInfo.prototype);

  // One canvas feeds every track the site asks for; frames flow only while a track is live.
  let canvas = null, context = null, source = null, liveTracks = 0, busy = false, pending = null;
  const stats = { frames: 0, lastLatencyMs: null, state: "idle" };
  Object.defineProperty(window, "__lockedGazeStats", { value: stats });

  // While no frames arrive, the placeholder keeps changing: a still canvas produces no new
  // video frames, and meeting sites then report that the camera might be blocked.
  let message = "Starting Locked Gaze…", detail = "", lastFrameAt = 0;
  function drawMessage(text, why) {
    if (text) { message = text; detail = why || ""; }
    context.fillStyle = "#101418"; context.fillRect(0, 0, WIDTH, HEIGHT);
    context.fillStyle = "#e8e8e8"; context.font = "36px -apple-system, system-ui, sans-serif";
    context.textAlign = "center"; context.fillText(message, WIDTH / 2, HEIGHT / 2);
    if (detail) {
      context.fillStyle = "#8a929c"; context.font = "20px -apple-system, system-ui, sans-serif";
      context.fillText(detail.slice(0, 110), WIDTH / 2, HEIGHT / 2 + 100);
    }
    const phase = (Date.now() / 400) % 3;
    for (let i = 0; i < 3; i++) {
      context.fillStyle = i <= phase ? "#e8e8e8" : "#3a4048";
      context.beginPath(); context.arc(WIDTH / 2 - 30 + i * 30, HEIGHT / 2 + 50, 7, 0, Math.PI * 2); context.fill();
    }
  }
  setInterval(() => {
    // A short gap keeps the last frame; only a longer one shows the placeholder.
    if (context && liveTracks > 0 && Date.now() - lastFrameAt > 1000) drawMessage();
  }, 200);

  function ensureSource() {
    if (source) return source;
    canvas = document.createElement("canvas");
    canvas.width = WIDTH; canvas.height = HEIGHT;
    context = canvas.getContext("2d", { alpha: false });
    drawMessage("Starting Locked Gaze…");
    source = canvas.captureStream(FPS).getVideoTracks()[0];
    return source;
  }

  async function drawFrame(frame) {
    busy = true;
    try {
      const bitmap = await createImageBitmap(new Blob([frame.jpeg], { type: "image/jpeg" }));
      if (liveTracks > 0) context.drawImage(bitmap, 0, 0, WIDTH, HEIGHT);
      bitmap.close();
      stats.frames++; stats.lastLatencyMs = Date.now() - frame.t0; lastFrameAt = Date.now();
    } catch {}
    busy = false;
    if (pending) { const next = pending; pending = null; drawFrame(next); }
  }

  window.addEventListener("message", (event) => {
    const data = event.data;
    if (event.source !== window || !data || data[TAG] !== "bridge") return;
    if (data.type === "frame") {
      stats.state = "streaming";
      if (busy) pending = data; else drawFrame(data);
    } else if (data.type === "error") {
      stats.state = "unavailable";
      stats.lastError = data.detail || data.message;
      if (context) {
        message = data.message || "Locked Gaze is not running"; detail = data.detail || "";
        if (Date.now() - lastFrameAt > 1000) drawMessage();
      }
    }
  });

  const tell = (type) => window.postMessage({ [TAG]: "page", type }, location.origin);

  function makeTrack() {
    const track = ensureSource().clone();
    if (liveTracks++ === 0) { stats.state = "starting"; drawMessage("Starting Locked Gaze…"); tell("start"); }
    let ended = false;
    const release = () => {
      if (ended) return; ended = true;
      if (--liveTracks === 0) { stats.state = "idle"; tell("stop"); }
    };
    const stop = track.stop.bind(track);
    Object.defineProperties(track, {
      label: { get: () => LABEL },
      stop: { value: () => { release(); stop(); } },
      getSettings: { value: () => ({ deviceId: DEVICE_ID, groupId: GROUP_ID, width: WIDTH, height: HEIGHT, frameRate: FPS, aspectRatio: WIDTH / HEIGHT, resizeMode: "none" }) },
      getCapabilities: { value: capabilities },
      applyConstraints: { value: async () => {} },
    });
    track.addEventListener("ended", release);
    return track;
  }

  function requestedIds(video) {
    const id = video?.deviceId;
    if (id == null) return null;
    const pick = (v) => (typeof v === "object" && !Array.isArray(v) ? v.exact ?? v.ideal : v);
    return [pick(id)].flat().filter(Boolean);
  }

  function wantsLockedGaze(constraints) {
    const video = constraints?.video;
    if (!video) return false;
    const ids = requestedIds(video);
    // No explicit device: Locked Gaze is listed first, so it is the default camera.
    return ids === null || ids.length === 0 || ids.includes(DEVICE_ID);
  }

  media.enumerateDevices = async function enumerateDevices() {
    const devices = await originalEnumerate();
    return [deviceInfo, ...devices];
  };

  // The browser's own camera permission gates Locked Gaze Camera: a site gets frames only
  // after the person allowed it the camera, exactly as with a real camera. When it is not
  // granted yet, the browser's prompt is shown by briefly asking for the real camera.
  let permitted = false;
  async function ensureCameraPermission() {
    if (permitted) return;
    try {
      const status = await navigator.permissions.query({ name: "camera" });
      if (status.state === "granted") { permitted = true; return; }
      if (status.state === "denied") throw new DOMException("Camera access is not allowed for this site.", "NotAllowedError");
    } catch (error) {
      if (error?.name === "NotAllowedError") throw error;
      // Browsers without the camera permission query fall through to the prompt.
    }
    const probe = await originalGetUserMedia({ video: true });
    probe.getTracks().forEach((track) => track.stop());
    permitted = true;
  }

  media.getUserMedia = async function getUserMedia(constraints) {
    if (!wantsLockedGaze(constraints)) return originalGetUserMedia(constraints);
    await ensureCameraPermission();
    const stream = constraints.audio ? await originalGetUserMedia({ audio: constraints.audio }) : new MediaStream();
    stream.addTrack(makeTrack());
    return stream;
  };

  // Legacy entry point some sites still call.
  if (navigator.getUserMedia) {
    navigator.getUserMedia = (constraints, ok, fail) => media.getUserMedia(constraints).then(ok, fail);
  }
})();
