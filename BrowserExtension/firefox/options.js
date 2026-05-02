const storage = globalThis.browser?.storage?.local || globalThis.chrome?.storage?.local;
const defaults = { showFloatingButton: true, blocklist: [], allowlist: [], allowlistMode: false };

const fields = {
  showFloatingButton: document.getElementById('showFloatingButton'),
  blocklist: document.getElementById('blocklist'),
  allowlist: document.getElementById('allowlist'),
  allowlistMode: document.getElementById('allowlistMode'),
  status: document.getElementById('status')
};

function storageGet(values) {
  const result = storage.get(values);
  return result?.then ? result : new Promise(resolve => storage.get(values, resolve));
}

function storageSet(values) {
  const result = storage.set(values);
  return result?.then ? result : new Promise(resolve => storage.set(values, resolve));
}

function parseDomains(value) {
  return value.split(/[\n,]/).map(domain => domain.trim()).filter(Boolean);
}

function formatDomains(domains) {
  return (domains || []).join('\n');
}

async function loadOptions() {
  const config = await storageGet(defaults);
  fields.showFloatingButton.checked = config.showFloatingButton !== false;
  fields.blocklist.value = formatDomains(config.blocklist);
  fields.allowlist.value = formatDomains(config.allowlist);
  fields.allowlistMode.checked = Boolean(config.allowlistMode);
}

async function saveOptions() {
  await storageSet({
    showFloatingButton: fields.showFloatingButton.checked,
    blocklist: parseDomains(fields.blocklist.value),
    allowlist: parseDomains(fields.allowlist.value),
    allowlistMode: fields.allowlistMode.checked
  });
  fields.status.textContent = 'Saved';
  setTimeout(() => { fields.status.textContent = ''; }, 1600);
}

document.getElementById('save').addEventListener('click', saveOptions);
loadOptions();
