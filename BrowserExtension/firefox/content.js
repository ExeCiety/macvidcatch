let candidate = null;
let button = null;
let lastYouTubeUrl = '';

browser.runtime.onMessage.addListener(message => {
  if (message.type !== 'MDMPRO_MEDIA_CANDIDATE') return;
  setCandidate(message);
});

detectYouTubePageCandidate();
setInterval(detectYouTubePageCandidate, 1000);

function setCandidate(message) {
  if (candidate && mediaPriority(message.media) < mediaPriority(candidate.media)) return;

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
  if (mimeType.includes('mpegurl') || url.includes('.m3u8')) return 100;
  if (mimeType === 'application/x-macvidcatch-youtube') return 90;
  if (mimeType.startsWith('video/') || /\.(mp4|mov|webm|m4v)([?#]|$)/i.test(url)) return 50;
  return 10;
}

function detectYouTubePageCandidate() {
  const pageUrl = youtubeDownloadUrl();
  if (!pageUrl || pageUrl === lastYouTubeUrl) return;
  lastYouTubeUrl = pageUrl;

  browser.storage.local.get({ blocklist: [], allowlist: [], allowlistMode: false }).then(config => {
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
  }).catch(() => {});
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
    button.addEventListener('click', sendToApp);
    document.documentElement.appendChild(button);
  }
  button.style.display = 'block';
}

function hideButton() {
  if (button) button.style.display = 'none';
}

function sendToApp() {
  if (!candidate) return;
  const params = new URLSearchParams({
    url: candidate.media.url,
    pageUrl: window.location.href,
    title: candidate.media.title || document.title || '',
    mimeType: candidate.media.mimeType || '',
    browser: 'firefox'
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
