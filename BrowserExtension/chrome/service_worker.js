const mediaExtensions = ['.mp4', '.mov', '.webm', '.m4v', '.m3u8'];
const mediaTypes = ['video/mp4', 'video/quicktime', 'video/webm', 'application/vnd.apple.mpegurl', 'application/x-mpegurl'];
const drmHeaders = ['x-drm', 'x-widevine', 'x-playready', 'x-fairplay'];
const hlsAnalysisCache = new Map();

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== 'MACVIDCATCH_ANALYZE_HLS') return false;

  analyzeHlsPlaylist(message.url)
    .then(sendResponse)
    .catch(() => sendResponse({ isMaster: false, qualityOptions: [] }));
  return true;
});

chrome.webRequest.onHeadersReceived.addListener((details) => {
  const url = new URL(details.url);
  const headers = Object.fromEntries((details.responseHeaders || []).map(h => [h.name.toLowerCase(), h.value || '']));
  const contentType = (headers['content-type'] || '').toLowerCase().split(';')[0];
  const isMedia = mediaExtensions.some(ext => url.pathname.toLowerCase().includes(ext)) || mediaTypes.includes(contentType);
  const isDrm = drmHeaders.some(name => headers[name]) || /keyformat|widevine|playready|fairplay/i.test(JSON.stringify(headers));
  if (!isMedia) return;
  chrome.storage.local.get({ blocklist: [], allowlist: [], allowlistMode: false, showFloatingButton: true }, config => {
    const blocked = config.blocklist.some(domain => url.hostname.includes(domain));
    const allowed = !config.allowlistMode || config.allowlist.some(domain => url.hostname.includes(domain));
    sendMediaCandidate(details.tabId, url, contentType, isDrm, allowed && !blocked);
  });
}, { urls: ['http://*/*', 'https://*/*'], types: ['media', 'xmlhttprequest', 'other'] }, ['responseHeaders']);

async function sendMediaCandidate(tabId, url, contentType, isDrm, isAllowedByDomainPolicy) {
  if (tabId < 0) return;

  const hlsAnalysis = url.href.toLowerCase().includes('.m3u8') || contentType.includes('mpegurl')
    ? await analyzeHlsPlaylist(url.href)
    : { isMaster: false, qualityOptions: [] };

  chrome.tabs.sendMessage(tabId, {
      type: 'MACVIDCATCH_MEDIA_CANDIDATE',
      media: {
        url: url.href,
        mimeType: contentType,
        title: documentTitleFromUrl(url),
        quality: '',
        isDrmProtected: isDrm,
        isHlsMaster: hlsAnalysis.isMaster,
        qualityOptions: hlsAnalysis.qualityOptions
      },
      policy: { isAllowedByUser: true, isAllowedByDomainPolicy }
    }).catch(() => {});
}

function documentTitleFromUrl(url) {
  const last = url.pathname.split('/').filter(Boolean).pop();
  return last ? decodeURIComponent(last) : url.hostname;
}

async function analyzeHlsPlaylist(url) {
  if (!url || !url.toLowerCase().includes('.m3u8')) return { isMaster: false, qualityOptions: [] };
  if (hlsAnalysisCache.has(url)) return hlsAnalysisCache.get(url);

  const analysisPromise = fetch(url, { credentials: 'include' })
    .then(response => response.text())
    .then(text => {
      const heights = [...text.matchAll(/RESOLUTION=\d+x(\d+)/gi)]
        .map(match => Number(match[1]))
        .filter(height => Number.isFinite(height) && height > 0);
      const qualityOptions = [...new Set(heights)]
        .sort((a, b) => b - a)
        .map(height => ({ label: `${height}p`, value: String(height) }));
      return { isMaster: /#EXT-X-STREAM-INF/i.test(text), qualityOptions };
    })
    .catch(() => ({ isMaster: false, qualityOptions: [] }));

  hlsAnalysisCache.set(url, analysisPromise);
  return analysisPromise;
}
