let candidate = null;
let button = null;

chrome.runtime.onMessage.addListener(message => {
  if (message.type !== 'MDMPRO_MEDIA_CANDIDATE') return;
  candidate = message;
  if (candidate.media.isDrmProtected || !candidate.policy.isAllowedByDomainPolicy) {
    showNotice('Media ini tidak dapat diunduh karena proteksi atau batasan izin.');
    return;
  }
  showButton();
});

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
