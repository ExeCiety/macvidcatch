let candidate = null;
let button = null;
let lastYouTubeUrl = '';

chrome.runtime.onMessage.addListener(message => {
  if (message.type !== 'MDMPRO_MEDIA_CANDIDATE') return;
  setCandidate(message);
});

detectYouTubePageCandidate();
setInterval(detectYouTubePageCandidate, 1000);

function setCandidate(message) {
  candidate = message;
  if (candidate.media.isDrmProtected || !candidate.policy.isAllowedByDomainPolicy) {
    hideButton();
    showNotice('Media ini tidak dapat diunduh karena proteksi atau batasan izin.');
    return;
  }
  showButton();
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
        mimeType: 'application/x-vidcatchmac-youtube',
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
    button.id = 'vidcatchmac-floating-button';
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
    mimeType: candidate.media.mimeType || ''
  });
  const target = `vidcatchmac://download?${params.toString()}`;
  window.location.href = target;
}

function showNotice(text) {
  const notice = document.createElement('div');
  notice.id = 'vidcatchmac-notice';
  notice.textContent = text;
  document.documentElement.appendChild(notice);
  setTimeout(() => notice.remove(), 5000);
}
