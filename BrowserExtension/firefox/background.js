const mediaExtensions = ['.mp4', '.mov', '.webm', '.m4v', '.m3u8'];
const mediaTypes = ['video/mp4', 'video/quicktime', 'video/webm', 'application/vnd.apple.mpegurl', 'application/x-mpegurl'];
const drmHeaders = ['x-drm', 'x-widevine', 'x-playready', 'x-fairplay'];

browser.webRequest.onHeadersReceived.addListener((details) => {
  const url = new URL(details.url);
  const headers = Object.fromEntries((details.responseHeaders || []).map(h => [h.name.toLowerCase(), h.value || '']));
  const contentType = (headers['content-type'] || '').toLowerCase().split(';')[0];
  const isMedia = mediaExtensions.some(ext => url.pathname.toLowerCase().includes(ext)) || mediaTypes.includes(contentType);
  const isDrm = drmHeaders.some(name => headers[name]) || /keyformat|widevine|playready|fairplay/i.test(JSON.stringify(headers));
  if (!isMedia || details.tabId < 0) return;

  browser.storage.local.get({ blocklist: [], allowlist: [], allowlistMode: false }).then(config => {
    const blocked = config.blocklist.some(domain => domain && url.hostname.includes(domain));
    const allowed = !config.allowlistMode || config.allowlist.some(domain => domain && url.hostname.includes(domain));
    return browser.tabs.sendMessage(details.tabId, {
      type: 'MDMPRO_MEDIA_CANDIDATE',
      media: { url: details.url, mimeType: contentType, title: documentTitleFromUrl(url), quality: '', isDrmProtected: isDrm },
      policy: { isAllowedByUser: true, isAllowedByDomainPolicy: allowed && !blocked }
    });
  }).catch(() => {});
}, { urls: ['http://*/*', 'https://*/*'], types: ['media', 'xmlhttprequest', 'other'] }, ['responseHeaders']);

function documentTitleFromUrl(url) {
  const last = url.pathname.split('/').filter(Boolean).pop();
  return last ? decodeURIComponent(last) : url.hostname;
}
