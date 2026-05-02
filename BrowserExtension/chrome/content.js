let candidate = null;
let button = null;
let qualityDialog = null;
let lastYouTubeUrl = '';
let lastLocationHref = window.location.href;
let youtubeDetectionTimer = null;
const hlsAnalysisCache = new Map();
const recentHlsCandidates = [];

chrome.runtime.onMessage.addListener(message => {
  if (message.type !== 'MDMPRO_MEDIA_CANDIDATE') return;
  if (isYouTubePage() && message.media?.mimeType !== 'application/x-macvidcatch-youtube') {
    scheduleYouTubeDetection();
    return;
  }
  rememberHlsCandidate(message.media?.url);
  setCandidate(message);
});

detectYouTubePageCandidate();
setInterval(detectYouTubePageCandidate, 1000);
installYouTubeSpaNavigationHooks();

function setCandidate(message, options = {}) {
  const isSameMedia = candidate?.media?.url === message.media?.url;
  const nextPriority = mediaPriority(message.media);
  const currentPriority = candidate ? mediaPriority(candidate.media) : -1;
  if (!options.force) {
    if (candidate && nextPriority < currentPriority) return;
    if (candidate && nextPriority === currentPriority && candidate.media.qualityOptions?.length) return;
    if (qualityDialog && candidate && nextPriority <= currentPriority) return;
  }

  candidate = message;
  if (!isSameMedia) closeQualityDialog();
  if (candidate.media.isDrmProtected || !candidate.policy.isAllowedByDomainPolicy) {
    hideButton();
    showNotice('This media cannot be downloaded because it is protected or restricted.');
    return;
  }
  showButton();

  if (isHlsMedia(candidate.media)) promoteMasterPlaylistCandidate(candidate);
}

function mediaPriority(media) {
  const url = (media.url || '').toLowerCase();
  const mimeType = (media.mimeType || '').toLowerCase();
  if (media.isHlsMaster) return 120;
  if (media.qualityOptions?.length) return 110;
  if (mimeType.includes('mpegurl') || url.includes('.m3u8')) return 100;
  if (mimeType === 'application/x-macvidcatch-youtube') return 90;
  if (mimeType.startsWith('video/') || /\.(mp4|mov|webm|m4v)([?#]|$)/i.test(url)) return 50;
  return 10;
}

function isHlsMedia(media) {
  const url = (media.url || '').toLowerCase();
  const mimeType = (media.mimeType || '').toLowerCase();
  return mimeType.includes('mpegurl') || url.includes('.m3u8');
}

function rememberHlsCandidate(url) {
  if (!url || !url.toLowerCase().includes('.m3u8')) return;
  recentHlsCandidates.unshift(url);
  const unique = [...new Set(recentHlsCandidates)];
  recentHlsCandidates.splice(0, recentHlsCandidates.length, ...unique.slice(0, 30));
}

function detectYouTubePageCandidate() {
  if (window.location.href !== lastLocationHref) {
    lastLocationHref = window.location.href;
    lastYouTubeUrl = '';
    closeQualityDialog();
  }

  const video = currentYouTubeVideo();
  if (!video || video.url === lastYouTubeUrl) return;
  lastYouTubeUrl = video.url;

  chrome.storage.local.get({ blocklist: [], allowlist: [], allowlistMode: false }, config => {
    if (currentYouTubeVideo()?.url !== video.url) return;
    setCandidate(youtubeCandidateMessage(video, isAllowedByDomainPolicy(config)), { force: true });
  });
}

async function refreshYouTubeCandidateForClick() {
  detectYouTubePageCandidate();
  const video = currentYouTubeVideo();
  if (!video || candidate?.media?.url === video.url) return;
  lastYouTubeUrl = video.url;
  const config = await chrome.storage.local.get({ blocklist: [], allowlist: [], allowlistMode: false });
  candidate = youtubeCandidateMessage(video, isAllowedByDomainPolicy(config));
  closeQualityDialog();
  if (candidate.policy.isAllowedByDomainPolicy) showButton();
  else hideButton();
}

function installYouTubeSpaNavigationHooks() {
  window.addEventListener('yt-navigate-start', scheduleYouTubeDetection, true);
  window.addEventListener('yt-navigate-finish', scheduleYouTubeDetection, true);
  window.addEventListener('yt-page-data-updated', scheduleYouTubeDetection, true);
  window.addEventListener('popstate', scheduleYouTubeDetection, true);

  const originalPushState = history.pushState;
  history.pushState = function pushState(...args) {
    const result = originalPushState.apply(this, args);
    scheduleYouTubeDetection();
    return result;
  };

  const originalReplaceState = history.replaceState;
  history.replaceState = function replaceState(...args) {
    const result = originalReplaceState.apply(this, args);
    scheduleYouTubeDetection();
    return result;
  };
}

function scheduleYouTubeDetection() {
  if (youtubeDetectionTimer) clearTimeout(youtubeDetectionTimer);
  lastYouTubeUrl = '';
  closeQualityDialog();
  youtubeDetectionTimer = setTimeout(() => {
    youtubeDetectionTimer = null;
    detectYouTubePageCandidate();
  }, 250);
}

function isAllowedByDomainPolicy(config) {
  const hostname = window.location.hostname;
  const blocked = config.blocklist.some(domain => domain && hostname.includes(domain));
  const allowed = !config.allowlistMode || config.allowlist.some(domain => domain && hostname.includes(domain));
  return allowed && !blocked;
}

function youtubeCandidateMessage(video, isAllowedByDomainPolicy) {
  return {
    type: 'MDMPRO_MEDIA_CANDIDATE',
    media: {
      url: video.url,
      mimeType: 'application/x-macvidcatch-youtube',
      title: video.title,
      quality: '',
      isDrmProtected: false
    },
    policy: { isAllowedByUser: true, isAllowedByDomainPolicy }
  };
}

function currentYouTubeVideo() {
  if (!isYouTubePage()) return null;

  const hostname = window.location.hostname.replace(/^www\./, '');

  const url = new URL(window.location.href);
  const title = youtubePageTitle();
  if (hostname === 'youtu.be') return { url: url.href, title };

  if (url.pathname === '/watch' && url.searchParams.get('v')) {
    const videoID = url.searchParams.get('v');
    const canonicalUrl = `https://www.youtube.com/watch?v=${encodeURIComponent(videoID)}`;
    const playerVideo = currentYouTubePlayerVideo();
    return {
      url: canonicalUrl,
      title: playerVideo?.url === canonicalUrl ? playerVideo.title : title
    };
  }

  const shortsMatch = url.pathname.match(/^\/shorts\/([^/?#]+)/);
  if (shortsMatch) {
    return { url: `https://www.youtube.com/shorts/${encodeURIComponent(shortsMatch[1])}`, title };
  }

  const playerVideo = currentYouTubePlayerVideo();
  if (playerVideo) return playerVideo;

  const selectedPlaylistVideo = currentYouTubeSelectedPlaylistVideo();
  if (selectedPlaylistVideo) return selectedPlaylistVideo;

  return null;
}

function isYouTubePage() {
  const hostname = window.location.hostname.replace(/^www\./, '');
  return hostname === 'youtube.com' || hostname === 'm.youtube.com' || hostname === 'youtu.be';
}

function currentYouTubeSelectedPlaylistVideo() {
  const selectedItem = document.querySelector('ytd-playlist-panel-video-renderer[selected], ytd-playlist-panel-video-renderer[is-active]');
  const link = selectedItem?.querySelector('a#wc-endpoint[href], a[href*="/watch?"]');
  const href = link?.getAttribute('href');
  if (!href) return null;

  const url = new URL(href, window.location.origin);
  const videoID = url.searchParams.get('v');
  if (!videoID) return null;

  return {
    url: `https://www.youtube.com/watch?v=${encodeURIComponent(videoID)}`,
    title: selectedPlaylistTitle(selectedItem) || youtubePageTitle()
  };
}

function selectedPlaylistTitle(selectedItem) {
  return (
    selectedItem.querySelector('#video-title')?.textContent ||
    selectedItem.querySelector('[id="video-title"]')?.textContent ||
    ''
  ).trim();
}

function currentYouTubePlayerVideo() {
  const player = document.querySelector('#movie_player');
  const data = player?.getVideoData?.();
  const videoID = data?.video_id || data?.videoId;
  if (!videoID) return null;
  return {
    url: `https://www.youtube.com/watch?v=${encodeURIComponent(videoID)}`,
    title: (data.title || youtubePageTitle()).trim()
  };
}

function youtubePageTitle() {
  return (
    document.querySelector('ytd-watch-metadata h1 yt-formatted-string')?.textContent ||
    document.querySelector('h1.ytd-watch-metadata')?.textContent ||
    document.title.replace(/\s+-\s+YouTube$/, '') ||
    ''
  ).trim();
}

function showButton() {
  if (!button) {
    button = document.createElement('button');
    button.id = 'macvidcatch-floating-button';
    button.textContent = 'Download';
    button.addEventListener('click', handleDownloadClick);
    document.documentElement.appendChild(button);
  }
  button.style.display = 'block';
}

function hideButton() {
  if (button) button.style.display = 'none';
}

async function handleDownloadClick() {
  await refreshYouTubeCandidateForClick();
  if (!candidate) return;
  if (!candidate.policy.isAllowedByDomainPolicy) return;
  if (shouldAskQuality(candidate.media)) {
    await promoteBestHlsCandidateForClick();
    const options = await qualityOptionsFor(candidate.media);
    showQualityDialog(options);
    return;
  }
  await sendToApp('best');
}

function shouldAskQuality(media) {
  const url = (media.url || '').toLowerCase();
  const mimeType = (media.mimeType || '').toLowerCase();
  return mimeType.includes('mpegurl') || url.includes('.m3u8') || mimeType === 'application/x-macvidcatch-youtube';
}

async function qualityOptionsFor(media) {
  if (media.qualityOptions?.length) return [{ label: 'Best available', value: 'best' }, ...media.qualityOptions];
  const analysis = await analyzeHlsPlaylist(media.url);
  if (analysis.qualityOptions.length > 0) {
    media.qualityOptions = analysis.qualityOptions;
    return [{ label: 'Best available', value: 'best' }, ...analysis.qualityOptions];
  }
  return [
    { label: 'Best available', value: 'best' },
    { label: '1080p or lower', value: '1080' },
    { label: '720p or lower', value: '720' },
    { label: '480p or lower', value: '480' },
    { label: '360p or lower', value: '360' }
  ];
}

async function analyzeHlsPlaylist(url) {
  if (!url || !url.toLowerCase().includes('.m3u8')) return { isMaster: false, qualityOptions: [] };
  if (hlsAnalysisCache.has(url)) return hlsAnalysisCache.get(url);

  const analysisPromise = chrome.runtime.sendMessage({ type: 'MACVIDCATCH_ANALYZE_HLS', url })
    .then(result => result || { isMaster: false, qualityOptions: [] })
    .catch(() => ({ isMaster: false, qualityOptions: [] }));

  hlsAnalysisCache.set(url, analysisPromise);
  return analysisPromise;
}

async function promoteMasterPlaylistCandidate(message) {
  const originalUrl = message.media?.url;
  const analysis = await analyzeHlsPlaylist(originalUrl);
  if (candidate?.media?.url !== originalUrl || !analysis.isMaster) return;
  candidate.media.qualityOptions = analysis.qualityOptions;
}

async function promoteBestHlsCandidateForClick() {
  if (!candidate || !isHlsMedia(candidate.media)) return;

  const best = await bestRecentMasterPlaylist(candidate.media.url);
  if (!best || best.url === candidate.media.url) return;

  candidate = {
    ...candidate,
    media: {
      ...candidate.media,
      url: best.url,
      qualityOptions: best.qualityOptions
    }
  };
}

async function bestRecentMasterPlaylist(currentUrl) {
  const urls = recentHlsUrls(currentUrl).slice(0, 12);
  const analyses = await Promise.all(urls.map(async url => ({ url, ...(await analyzeHlsPlaylist(url)) })));
  const masters = analyses.filter(item => item.isMaster);
  if (!masters.length) return null;
  masters.sort((a, b) => masterPlaylistScore(b) - masterPlaylistScore(a));
  return masters[0];
}

function masterPlaylistScore(item) {
  const path = safeUrlPath(item.url);
  let score = item.qualityOptions.length * 10;
  if (/master|playlist|index/i.test(path)) score += 50;
  if (/chunk|segment|frag|audio|subtitle/i.test(path)) score -= 50;
  return score;
}

function safeUrlPath(url) {
  try {
    return new URL(url).pathname;
  } catch (_) {
    return url || '';
  }
}

function recentHlsUrls(currentUrl) {
  try {
    const current = new URL(currentUrl);
    const seen = new Set([current.href]);
    for (const candidateUrl of recentHlsCandidates) {
      const url = new URL(candidateUrl);
      if (url.origin === current.origin) seen.add(url.href);
    }
    for (const entry of performance.getEntriesByType('resource').slice().reverse()) {
      if (!entry.name || !entry.name.toLowerCase().includes('.m3u8')) continue;
      const url = new URL(entry.name);
      if (url.origin !== current.origin) continue;
      seen.add(url.href);
    }
    return [...seen];
  } catch (_) {
    return currentUrl ? [currentUrl] : [];
  }
}

function showQualityDialog(options) {
  closeQualityDialog();

  qualityDialog = document.createElement('div');
  qualityDialog.id = 'macvidcatch-quality-dialog';
  qualityDialog.innerHTML = `
    <div class="macvidcatch-quality-card" role="dialog" aria-modal="true" aria-label="Choose video quality">
      <div class="macvidcatch-quality-title">Choose video quality</div>
      <div class="macvidcatch-quality-subtitle">Make sure this is the correct video before downloading.</div>
      <div class="macvidcatch-quality-media"></div>
      <div class="macvidcatch-quality-options"></div>
      <div class="macvidcatch-quality-actions"><button type="button" data-cancel="true">Cancel</button></div>
    </div>`;

  const mediaContainer = qualityDialog.querySelector('.macvidcatch-quality-media');
  mediaContainer.appendChild(mediaDetailRow('File', mediaDisplayName()));
  mediaContainer.appendChild(mediaDetailRow('URL', candidate?.media?.url || window.location.href));

  const optionsContainer = qualityDialog.querySelector('.macvidcatch-quality-options');
  for (const option of options) {
    const optionButton = document.createElement('button');
    optionButton.type = 'button';
    optionButton.textContent = `Download ${option.label}`;
    optionButton.addEventListener('click', async () => {
      qualityDialog?.remove();
      qualityDialog = null;
      await sendToApp(option.value);
    });
    optionsContainer.appendChild(optionButton);
  }

  qualityDialog.querySelector('[data-cancel]').addEventListener('click', () => {
    qualityDialog?.remove();
    qualityDialog = null;
  });
  qualityDialog.addEventListener('click', event => {
    if (event.target === qualityDialog) {
      qualityDialog.remove();
      qualityDialog = null;
    }
  });
  document.documentElement.appendChild(qualityDialog);
}

function closeQualityDialog() {
  if (!qualityDialog) return;
  qualityDialog.remove();
  qualityDialog = null;
}

function mediaDetailRow(label, value) {
  const row = document.createElement('div');
  row.className = 'macvidcatch-quality-media-row';

  const labelElement = document.createElement('strong');
  labelElement.textContent = `${label}: `;
  row.appendChild(labelElement);

  const valueElement = document.createElement('span');
  valueElement.textContent = value || '-';
  row.appendChild(valueElement);

  return row;
}

function mediaDisplayName() {
  const title = isHlsMedia(candidate?.media) ? pageDisplayTitle() : candidate?.media?.title || pageDisplayTitle();
  return title.replace(/\s+-\s+YouTube$/, '').trim() || candidate?.media?.url || 'Unknown media';
}

function pageDisplayTitle() {
  return document.title || document.querySelector('meta[property="og:title"]')?.content || document.querySelector('h1')?.textContent || '';
}

async function sendToApp(quality) {
  await refreshYouTubeCandidateForClick();
  if (!candidate) return;
  if (!candidate.policy.isAllowedByDomainPolicy) return;
  const params = new URLSearchParams({
    url: candidate.media.url,
    pageUrl: window.location.href,
    title: mediaDisplayName(),
    mimeType: candidate.media.mimeType || '',
    quality: quality || candidate.media.quality || 'best',
    browser: 'chrome'
  });
  const target = `macvidcatch://download?${params.toString()}`;
  window.location.href = target;
}

function showNotice(text) {
  const notice = document.createElement('div');
  notice.id = 'macvidcatch-notice';
  notice.textContent = text;
  document.documentElement.appendChild(notice);
  setTimeout(() => notice.remove(), 5000);
}
