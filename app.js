'use strict';

// ---------------------------------------------------------------------------
// Persistent state (localStorage)
// ---------------------------------------------------------------------------
const STORE_KEY = 'pdfDriveReader';
const DEFAULTS = {
  clientId: '',
  folderPath: '',
  order: 'newest',
  rate: 1.0,
  voiceURI: '',
  skipPlayed: true,
  announce: true,
  played: {},          // driveItemId -> true once finished
  position: null,      // { id, chunk } where we stopped last time
};

function loadState() {
  try {
    return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(STORE_KEY) || '{}') };
  } catch {
    return { ...DEFAULTS };
  }
}
function saveState() {
  try { localStorage.setItem(STORE_KEY, JSON.stringify(state)); } catch {}
}
const state = loadState();

const $ = (id) => document.getElementById(id);
const GRAPH = 'https://graph.microsoft.com/v1.0';
const SCOPES = ['Files.Read'];

pdfjsLib.GlobalWorkerOptions.workerSrc =
  'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';

// ---------------------------------------------------------------------------
// Microsoft sign-in (MSAL)
// ---------------------------------------------------------------------------
let msalApp = null;
let account = null;

async function initAuth() {
  if (!state.clientId) return;
  msalApp = new msal.PublicClientApplication({
    auth: {
      clientId: state.clientId,
      // "common" accepts both personal OneDrive and work/school accounts.
      authority: 'https://login.microsoftonline.com/common',
      redirectUri: location.origin + location.pathname,
    },
    cache: { cacheLocation: 'localStorage' },
  });
  if (msalApp.initialize) await msalApp.initialize();
  const result = await msalApp.handleRedirectPromise();
  account = result?.account || msalApp.getAllAccounts()[0] || null;
}

async function getToken() {
  try {
    const r = await msalApp.acquireTokenSilent({ scopes: SCOPES, account });
    return r.accessToken;
  } catch (e) {
    await msalApp.acquireTokenRedirect({ scopes: SCOPES, account });
    throw e; // page navigates away
  }
}

async function graph(path) {
  const token = await getToken();
  const res = await fetch(path.startsWith('http') ? path : GRAPH + path, {
    headers: { Authorization: 'Bearer ' + token },
  });
  if (!res.ok) throw new Error(`OneDrive request failed (${res.status})`);
  return res.json();
}

// ---------------------------------------------------------------------------
// OneDrive folder listing
// ---------------------------------------------------------------------------
let files = [];        // sorted list of PDF drive items
let currentIdx = -1;

function folderUrl() {
  const p = state.folderPath.trim().replace(/^\/+|\/+$/g, '');
  if (!p) return '/me/drive/root/children?$top=200';
  const encoded = p.split('/').map(encodeURIComponent).join('/');
  return `/me/drive/root:/${encoded}:/children?$top=200`;
}

async function refreshFiles() {
  setStatus('Checking OneDrive…');
  const items = [];
  let url = folderUrl();
  while (url) {
    const page = await graph(url);
    items.push(...page.value);
    url = page['@odata.nextLink'];
  }
  const currentId = files[currentIdx]?.id;
  files = items
    .filter((it) => it.file && /\.pdf$/i.test(it.name))
    .sort((a, b) => {
      const d = new Date(b.createdDateTime) - new Date(a.createdDateTime);
      return state.order === 'newest' ? d : -d;
    });
  currentIdx = currentId ? files.findIndex((f) => f.id === currentId) : -1;
  renderList();
  setStatus(files.length ? `${files.length} PDF(s) in folder` : 'No PDFs found in that folder');
}

function renderList() {
  const ol = $('fileList');
  ol.innerHTML = '';
  files.forEach((f, i) => {
    const li = document.createElement('li');
    li.textContent = prettyName(f.name);
    const small = document.createElement('small');
    small.textContent = new Date(f.createdDateTime).toLocaleString() + (state.played[f.id] ? ' · finished' : '');
    li.appendChild(small);
    if (state.played[f.id]) li.classList.add('played');
    if (i === currentIdx) li.classList.add('current');
    li.addEventListener('click', () => startFile(i, 0));
    ol.appendChild(li);
  });
}

const prettyName = (name) => name.replace(/\.pdf$/i, '').replace(/[_]+/g, ' ');

// ---------------------------------------------------------------------------
// PDF -> text -> speakable chunks
// ---------------------------------------------------------------------------
const textCache = new Map(); // id -> Promise<string[]>

function getChunks(item) {
  if (!textCache.has(item.id)) {
    const p = extractChunks(item).catch((e) => { textCache.delete(item.id); throw e; });
    textCache.set(item.id, p);
  }
  return textCache.get(item.id);
}

async function extractChunks(item) {
  // Fetch fresh metadata so the pre-authenticated download URL is not expired.
  const meta = await graph(`/me/drive/items/${item.id}`);
  const res = await fetch(meta['@microsoft.graph.downloadUrl']);
  if (!res.ok) throw new Error(`Download failed (${res.status})`);
  const pdf = await pdfjsLib.getDocument({ data: await res.arrayBuffer() }).promise;

  let text = '';
  for (let n = 1; n <= pdf.numPages; n++) {
    const page = await pdf.getPage(n);
    const content = await page.getTextContent();
    for (const it of content.items) {
      text += it.str + (it.hasEOL ? '\n' : '');
    }
    text += '\n';
  }
  return toChunks(cleanText(text));
}

function cleanText(t) {
  return t
    .replace(/(\w)-\n(\w)/g, '$1$2')      // re-join words hyphenated across lines
    .replace(/\s*\n\s*/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

// Mobile speech engines cut off long utterances, so speak sentence-sized pieces.
const MAX_CHUNK = 220;
function toChunks(text) {
  const sentences = text.match(/[^.!?]+[.!?]+["'”’)\]]*\s*|[^.!?]+$/g) || [];
  const out = [];
  for (let s of sentences) {
    s = s.trim();
    while (s.length > MAX_CHUNK) {
      let cut = s.lastIndexOf(', ', MAX_CHUNK);
      if (cut < MAX_CHUNK / 2) cut = s.lastIndexOf(' ', MAX_CHUNK);
      if (cut <= 0) cut = MAX_CHUNK;
      out.push(s.slice(0, cut + 1).trim());
      s = s.slice(cut + 1).trim();
    }
    if (s) out.push(s);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Playback
// ---------------------------------------------------------------------------
let playing = false;
let chunks = [];
let chunkIdx = 0;
let offset = 0;       // spoken intro pieces (title, notices) placed before the PDF text
let generation = 0;   // bumps on every cancel so stale onend callbacks are ignored

function pickNext(fromIdx) {
  for (let i = fromIdx + 1; i < files.length; i++) {
    if (!state.skipPlayed || !state.played[files[i].id]) return i;
  }
  return -1;
}

// `preface` is a short notice (e.g. "Skipping…") spoken before this file starts,
// so it isn't cut off by the cancel() that starting a file performs.
async function startFile(idx, startChunk, preface = '') {
  stopSpeech();
  if (idx < 0 || idx >= files.length) {
    currentIdx = -1;
    chunks = [];
    setTitle('All caught up');
    speakSystem(`${preface} That was the last PDF in the folder.`);
    setPlaying(false);
    return;
  }
  currentIdx = idx;
  const item = files[idx];
  setTitle(prettyName(item.name));
  renderList();
  setStatus('Loading PDF…');
  setPlaying(true);
  const gen = generation;
  try {
    chunks = await getChunks(item);
  } catch (e) {
    setStatus(e.message);
    if (gen === generation) return startFile(pickNext(idx), 0, 'Could not open this PDF. Skipping.');
    return;
  }
  if (gen !== generation) return; // user skipped while loading
  if (!chunks.length) {
    state.played[item.id] = true;
    saveState();
    return startFile(pickNext(idx), 0, 'This PDF has no readable text. Skipping.');
  }
  const intro = [];
  if (preface) intro.push(preface);
  if (state.announce && startChunk === 0) intro.push(`${prettyName(item.name)}.`);
  chunks = [...intro, ...chunks];
  offset = intro.length;
  chunkIdx = startChunk > 0 ? Math.min(startChunk + offset, chunks.length - 1) : 0;
  // Prefetch the next PDF while this one is read.
  const nxt = pickNext(idx);
  if (nxt >= 0) getChunks(files[nxt]).catch(() => {});
  speakCurrent();
}

function speakCurrent() {
  if (!playing) return;
  const item = files[currentIdx];
  if (chunkIdx >= chunks.length) {
    state.played[item.id] = true;
    state.position = null;
    saveState();
    const gen = generation;
    refreshFiles().catch(() => {}).finally(() => {
      if (gen === generation) startFile(pickNext(files.findIndex((f) => f.id === item.id)), 0);
    });
    return;
  }
  state.position = { id: item.id, chunk: Math.max(0, chunkIdx - offset) };
  saveState();
  updateProgress();

  const gen = generation;
  const u = new SpeechSynthesisUtterance(chunks[chunkIdx]);
  u.rate = state.rate;
  const voice = speechSynthesis.getVoices().find((v) => v.voiceURI === state.voiceURI);
  if (voice) u.voice = voice;
  u.onend = () => {
    if (gen !== generation) return;
    chunkIdx++;
    speakCurrent();
  };
  u.onerror = (e) => {
    if (gen !== generation || e.error === 'interrupted' || e.error === 'canceled') return;
    chunkIdx++;
    speakCurrent();
  };
  speechSynthesis.speak(u);
}

function speakSystem(text) {
  const u = new SpeechSynthesisUtterance(text);
  u.rate = state.rate;
  speechSynthesis.speak(u);
}

function stopSpeech() {
  generation++;
  speechSynthesis.cancel();
}

function play() {
  keepAwake();
  if (currentIdx >= 0 && chunks.length) {
    setPlaying(true);
    speakCurrent();
    return;
  }
  // Resume where we left off last time if that PDF is still in the folder.
  const pos = state.position;
  const resumeIdx = pos ? files.findIndex((f) => f.id === pos.id) : -1;
  if (resumeIdx >= 0) startFile(resumeIdx, pos.chunk);
  else startFile(pickNext(-1), 0);
}

function pause() {
  stopSpeech();
  setPlaying(false);
}

function skipSentences(n) {
  if (currentIdx < 0 || !chunks.length) return;
  stopSpeech();
  chunkIdx = Math.max(0, Math.min(chunks.length - 1, chunkIdx + n));
  if (playing) speakCurrent(); else updateProgress();
}

function nextFile() { startFile(pickNext(currentIdx), 0); }
function prevFile() { startFile(Math.max(0, currentIdx - 1), 0); }

// ---------------------------------------------------------------------------
// Hands-free helpers: screen wake lock + lock-screen / car media buttons
// ---------------------------------------------------------------------------
let wakeLock = null;
async function keepAwake() {
  try {
    if ('wakeLock' in navigator && !wakeLock) {
      wakeLock = await navigator.wakeLock.request('screen');
      wakeLock.addEventListener('release', () => { wakeLock = null; });
    }
  } catch {}
}
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && playing) keepAwake();
});

// Media Session controls only appear while an <audio> element is playing, so
// loop a silent clip. This lets steering-wheel / Bluetooth buttons work.
const silentAudio = new Audio(makeSilentWav());
silentAudio.loop = true;

function makeSilentWav() {
  const rate = 8000, n = rate; // 1 second, 8-bit mono
  const buf = new ArrayBuffer(44 + n);
  const v = new DataView(buf);
  const str = (o, s) => [...s].forEach((c, i) => v.setUint8(o + i, c.charCodeAt(0)));
  str(0, 'RIFF'); v.setUint32(4, 36 + n, true); str(8, 'WAVE');
  str(12, 'fmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
  v.setUint32(24, rate, true); v.setUint32(28, rate, true); v.setUint16(32, 1, true); v.setUint16(34, 8, true);
  str(36, 'data'); v.setUint32(40, n, true);
  for (let i = 0; i < n; i++) v.setUint8(44 + i, 128);
  return URL.createObjectURL(new Blob([buf], { type: 'audio/wav' }));
}

if ('mediaSession' in navigator) {
  const ms = navigator.mediaSession;
  ms.setActionHandler('play', play);
  ms.setActionHandler('pause', pause);
  ms.setActionHandler('nexttrack', nextFile);
  ms.setActionHandler('previoustrack', prevFile);
  try { ms.setActionHandler('seekbackward', () => skipSentences(-3)); } catch {}
  try { ms.setActionHandler('seekforward', () => skipSentences(3)); } catch {}
}

// ---------------------------------------------------------------------------
// UI
// ---------------------------------------------------------------------------
function setPlaying(p) {
  playing = p;
  $('playBtn').textContent = p ? '⏸' : '▶';
  $('playBtn').setAttribute('aria-label', p ? 'Pause' : 'Play');
  if (p) silentAudio.play().catch(() => {}); else silentAudio.pause();
  if ('mediaSession' in navigator) navigator.mediaSession.playbackState = p ? 'playing' : 'paused';
}

function setTitle(t) {
  $('nowTitle').textContent = t;
  if ('mediaSession' in navigator) {
    navigator.mediaSession.metadata = new MediaMetadata({ title: t, artist: 'PDF Drive Reader' });
  }
}

function setStatus(s) { $('status').textContent = s; }

function updateProgress() {
  $('progress').max = Math.max(1, chunks.length);
  $('progress').value = chunkIdx;
  setStatus(`Sentence ${chunkIdx + 1} of ${chunks.length}`);
}

function populateVoices() {
  const sel = $('voice');
  const voices = speechSynthesis.getVoices();
  sel.innerHTML = '<option value="">System default</option>';
  for (const v of voices) {
    const o = document.createElement('option');
    o.value = v.voiceURI;
    o.textContent = `${v.name} (${v.lang})`;
    sel.appendChild(o);
  }
  sel.value = state.voiceURI;
}
speechSynthesis.addEventListener?.('voiceschanged', populateVoices);

function fillSettings() {
  $('clientId').value = state.clientId;
  $('folderPath').value = state.folderPath;
  $('order').value = state.order;
  $('rate').value = state.rate;
  $('rateVal').textContent = state.rate + '×';
  $('skipPlayed').checked = state.skipPlayed;
  $('announce').checked = state.announce;
  populateVoices();
}

function show(section) {
  for (const id of ['setup', 'login', 'player']) $(id).hidden = id !== section;
}

$('rate').addEventListener('input', (e) => { $('rateVal').textContent = e.target.value + '×'; });
$('settingsBtn').addEventListener('click', () => { fillSettings(); show($('setup').hidden ? 'setup' : (account ? 'player' : 'login')); });

$('saveSettings').addEventListener('click', async () => {
  const idChanged = $('clientId').value.trim() !== state.clientId;
  Object.assign(state, {
    clientId: $('clientId').value.trim(),
    folderPath: $('folderPath').value.trim(),
    order: $('order').value,
    rate: parseFloat($('rate').value),
    voiceURI: $('voice').value,
    skipPlayed: $('skipPlayed').checked,
    announce: $('announce').checked,
  });
  saveState();
  if (idChanged) return location.reload();
  if (!account) return show('login');
  show('player');
  refreshFiles().catch((e) => setStatus(e.message));
});

$('resetPlayed').addEventListener('click', () => {
  state.played = {};
  state.position = null;
  saveState();
  renderList();
});

$('signIn').addEventListener('click', () => msalApp.loginRedirect({ scopes: SCOPES }));
$('signOut').addEventListener('click', () => msalApp?.logoutRedirect({ account }));

$('playBtn').addEventListener('click', () => (playing ? pause() : play()));
$('nextBtn').addEventListener('click', nextFile);
$('prevBtn').addEventListener('click', prevFile);
$('backBtn').addEventListener('click', () => skipSentences(-3));
$('fwdBtn').addEventListener('click', () => skipSentences(3));
$('refreshBtn').addEventListener('click', () => refreshFiles().catch((e) => setStatus(e.message)));

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------
(async function main() {
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
  fillSettings();
  if (!state.clientId) return show('setup');
  try {
    await initAuth();
  } catch (e) {
    show('setup');
    setStatus(e.message);
    return;
  }
  if (!account) return show('login');
  show('player');
  if (!state.folderPath) setStatus('Tip: set your folder in ⚙ settings');
  try {
    await refreshFiles();
    const pos = state.position && files.find((f) => f.id === state.position.id);
    setTitle(pos ? `Resume: ${prettyName(pos.name)}` : 'Press ▶ to start');
  } catch (e) {
    setStatus(e.message);
  }
})();
