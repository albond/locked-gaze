// Any site, by the person's choice: clicking the toolbar button on a page asks the browser
// for access to that site, registers the Locked Gaze content scripts there and reloads the
// page; clicking again on an enabled site turns it off. The built-in meeting sites are
// always on. Shared by the Chrome and Safari background scripts.
const api = globalThis.browser ?? globalThis.chrome;
const SCRIPT_PREFIX = "locked-gaze-site:";

function originPattern(url) {
  try {
    const parsed = new URL(url);
    return parsed.protocol === "https:" ? `${parsed.origin}/*` : null;
  } catch { return null; }
}

function builtIn(pattern) {
  const declared = api.runtime.getManifest().content_scripts?.flatMap((entry) => entry.matches) ?? [];
  const host = new URL(pattern.replace("/*", "/")).host;
  return declared.some((match) => {
    const declaredHost = match.replace(/^https:\/\//, "").replace(/\/\*$/, "");
    return declaredHost === host || (declaredHost.startsWith("*.") && host.endsWith(declaredHost.slice(1)));
  });
}

async function registered() {
  const scripts = await api.scripting.getRegisteredContentScripts();
  return new Set(scripts.filter((s) => s.id.startsWith(SCRIPT_PREFIX)).map((s) => s.matches[0]));
}

async function register(pattern) {
  const id = SCRIPT_PREFIX + pattern;
  const common = { matches: [pattern], runAt: "document_start", allFrames: true, persistAcrossSessions: true };
  await api.scripting.registerContentScripts([
    { ...common, id: id + ":main", js: ["inject-main.js"], world: "MAIN" },
    { ...common, id: id + ":bridge", js: ["inject-bridge.js"] },
  ]).catch(async (error) => {
    // A browser without dynamic registration (or without the page world) cannot add sites.
    await unregister(pattern);
    throw error;
  });
}

async function unregister(pattern) {
  const id = SCRIPT_PREFIX + pattern;
  await api.scripting.unregisterContentScripts({ ids: [id + ":main", id + ":bridge"] }).catch(() => {});
}

async function updateButton(tab) {
  if (!tab?.id) return;
  const pattern = originPattern(tab.url);
  const on = pattern && (builtIn(pattern) || (await registered()).has(pattern));
  const title = !pattern ? "Locked Gaze Camera works on secure (https) sites"
    : on && builtIn(pattern) ? "Locked Gaze Camera is on for this site"
    : on ? "Locked Gaze Camera is on for this site. Click to turn it off."
    : "Click to use Locked Gaze Camera on this site";
  api.action.setTitle({ tabId: tab.id, title });
  api.action.setBadgeText({ tabId: tab.id, text: on ? "ON" : "" });
  api.action.setBadgeBackgroundColor?.({ tabId: tab.id, color: "#E57B4F" });
}

api.action.onClicked.addListener(async (tab) => {
  const pattern = originPattern(tab.url);
  if (!pattern || builtIn(pattern)) return updateButton(tab);
  if ((await registered()).has(pattern)) {
    await unregister(pattern);
    await api.permissions.remove({ origins: [pattern] }).catch(() => {});
  } else {
    // Must run straight from the click: the browser shows its own permission prompt.
    const granted = await api.permissions.request({ origins: [pattern] });
    if (!granted) return updateButton(tab);
    await register(pattern);
  }
  api.tabs.reload(tab.id);
});

// Access removed in the browser's settings also removes the site.
api.permissions.onRemoved?.addListener(async ({ origins = [] }) => {
  for (const pattern of origins) await unregister(pattern);
});

api.tabs.onActivated.addListener(({ tabId }) => api.tabs.get(tabId).then(updateButton).catch(() => {}));
api.tabs.onUpdated.addListener((tabId, change, tab) => { if (change.status === "complete") updateButton(tab); });
