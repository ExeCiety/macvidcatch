let candidate = null;
let button = null;
let qualityDialog = null;
let lastYouTubeUrl = '';

chrome.runtime.onMessage.addListener(message => {
  if (message.type !== 'MDMPRO_MEDIA_CANDIDATE') return;
  setCandidate(message);
});

detectYouTubePageCandidate();
setInterval(detectYouTubePageCandidate, 1000);

async function setCandidate(message) {
  if (isHlsMedia(message.media)) {
    const qualityOptions = await parseHlsQualities(message.media.url);
    if (qualityOptions.length > 0) message.media.qualityOptions = qualityOptions;
  }

  const nextPriority = mediaPriority(message.media);
  const currentPriority = candidate ? mediaPriority(candidate.media) : -1;
  if (candidate && nextPriority < currentPriority) return;
  if (candidate && nextPriority === currentPriority && candidate.media.qualityOptions?.length) return;

  candidate = message;
  if (candidate.media.isDrmProtected || !candidate.policy.isAllowedByDomainPolicy) {
    hideButton();
    showNotice('Media ini tidak dapat diunduh karena proteksi atau batasan izin.');
    return;
  }
  showButton();
}

function mediaPriority(media) {
  const url = (media.url || '').toLowerCase();
  const mimeType = (media.mimeType || '').toLowerCase();
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

function detectYouTubePageCandidate() {
  const pageUrl = youtubeDownloadUrl();
  if (!pageUrl || pageUrl === lastYouTubeUrl) return;
  lastYouTubeUrl = pageUrl;

  chrome.storage.local.get({ blocklist: [], allowlist: [], allowlistMode: false }, config => {
    const hostname = window.location.hostname;
    const blocked = config.blocklist.some(domain => domain && hostname.includes(domain));
    const allowed = !config.allowlistMode || config.allowlist.some(domain => domain && hostname.includes(domain));
    setCandidate({
      type: 'MDMPRO_MEDIA_CANDIDATE',
      media: {
        url: pageUrl,
        mimeType: 'application/x-macvidcatch-youtube',
        title: document.title.replace(/\s+-\s+YouTube$/, ''),
        quality: '',
        isDrmProtected: false
      },
      policy: { isAllowedByUser: true, isAllowedByDomainPolicy: allowed && !blocked }
    });
  });
}

function youtubeDownloadUrl() {
  const hostname = window.location.hostname.replace(/^www\./, '');
  if (hostname !== 'youtube.com' && hostname !== 'm.youtube.com' && hostname !== 'youtu.be') return '';

  const url = new URL(window.location.href);
  if (hostname === 'youtu.be') return url.href;

  if (url.pathname === '/watch' && url.searchParams.get('v')) {
    return `https://www.youtube.com/watch?v=${encodeURIComponent(url.searchParams.get('v'))}`;
  }

  const shortsMatch = url.pathname.match(/^\/shorts\/([^/?#]+)/);
  if (shortsMatch) {
    return `https://www.youtube.com/shorts/${encodeURIComponent(shortsMatch[1])}`;
  }

  return '';
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
  if (!candidate) return;
  if (shouldAskQuality(candidate.media)) {
    const options = await qualityOptionsFor(candidate.media);
    showQualityDialog(options);
    return;
  }
  sendToApp('best');
}

function shouldAskQuality(media) {
  const url = (media.url || '').toLowerCase();
  const mimeType = (media.mimeType || '').toLowerCase();
  return mimeType.includes('mpegurl') || url.includes('.m3u8') || mimeType === 'application/x-macvidcatch-youtube';
}

async function qualityOptionsFor(media) {
  if (media.qualityOptions?.length) return [{ label: 'Best available', value: 'best' }, ...media.qualityOptions];
  const parsed = await parseHlsQualities(media.url);
  if (parsed.length > 0) return [{ label: 'Best available', value: 'best' }, ...parsed];
  return [
    { label: 'Best available', value: 'best' },
    { label: '1080p or lower', value: '1080' },
    { label: '720p or lower', value: '720' },
    { label: '480p or lower', value: '480' },
    { label: '360p or lower', value: '360' }
  ];
}

async function parseHlsQualities(url) {
  if (!url || !url.toLowerCase().includes('.m3u8')) return [];
  try {
    const response = await fetch(url, { credentials: 'include' });
    const text = await response.text();
    const heights = [...text.matchAll(/RESOLUTION=\d+x(\d+)/gi)]
      .map(match => Number(match[1]))
      .filter(height => Number.isFinite(height) && height > 0);
    return [...new Set(heights)]
      .sort((a, b) => b - a)
      .map(height => ({ label: `${height}p`, value: String(height) }));
  } catch (_) {
    return [];
  }
}

function showQualityDialog(options) {
  if (qualityDialog) qualityDialog.remove();

  qualityDialog = document.createElement('div');
  qualityDialog.id = 'macvidcatch-quality-dialog';
  qualityDialog.innerHTML = `
    <div class="macvidcatch-quality-card" role="dialog" aria-modal="true" aria-label="Choose video quality">
      <div class="macvidcatch-quality-title">Pilih kualitas video</div>
      <div class="macvidcatch-quality-subtitle">MacVidCatch akan membuka aplikasi setelah kualitas dipilih.</div>
      <div class="macvidcatch-quality-options"></div>
      <div class="macvidcatch-quality-actions"><button type="button" data-cancel="true">Cancel</button></div>
    </div>`;

  const optionsContainer = qualityDialog.querySelector('.macvidcatch-quality-options');
  for (const option of options) {
    const optionButton = document.createElement('button');
    optionButton.type = 'button';
    optionButton.textContent = option.label;
    optionButton.addEventListener('click', () => {
      qualityDialog?.remove();
      qualityDialog = null;
      sendToApp(option.value);
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

function sendToApp(quality) {
  if (!candidate) return;
  const params = new URLSearchParams({
    url: candidate.media.url,
    pageUrl: window.location.href,
    title: candidate.media.title || document.title || '',
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
