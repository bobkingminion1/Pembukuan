/* Service worker Pembukuan Perusahaan: aplikasi tetap bisa dibuka tanpa internet setelah dibuka sekali. */
const VERSI = 'pembukuan-434f08a0d3';
const INTI = ['./', './index.html', './manifest.webmanifest', './icon.svg', './icon-192.png', './icon-512.png', './apple-touch-icon.png'];
const PUSTAKA = ["https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js","https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js","https://cdn.jsdelivr.net/npm/jspdf-autotable@3.8.2/dist/jspdf.plugin.autotable.min.js","https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600;700&family=Newsreader:opsz,wght@6..72,500;6..72,600&display=swap"];
const LUAR = ['cdnjs.cloudflare.com', 'cdn.jsdelivr.net', 'fonts.googleapis.com', 'fonts.gstatic.com'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSI).then(c => c.addAll(INTI).then(() =>
    // pustaka Excel/PDF dan font disimpan sejak kunjungan pertama; gagal (offline) tidak menghalangi pemasangan
    Promise.all(PUSTAKA.map(u => fetch(u, { mode: 'no-cors' }).then(r => c.put(u, r)).catch(() => {}))))).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k.startsWith('pembukuan-') && k !== VERSI).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin === location.origin) {
    if (req.mode === 'navigate') {
      // halaman: coba jaringan dulu supaya pembaruan cepat sampai, cadangkan ke cache bila offline
      e.respondWith(fetch(req).then(r => { const cp = r.clone(); caches.open(VERSI).then(c => c.put('./index.html', cp)); return r; }).catch(() => caches.match('./index.html').then(r => r || caches.match('./'))));
      return;
    }
    e.respondWith(caches.match(req).then(r => r || fetch(req).then(n => { if (n.ok) { const cp = n.clone(); caches.open(VERSI).then(c => c.put(req, cp)); } return n; })));
    return;
  }
  if (LUAR.indexOf(url.hostname) >= 0) {
    // pustaka Excel/PDF dan font: pakai salinan tersimpan, perbarui diam-diam di latar belakang
    e.respondWith(caches.open(VERSI).then(c => c.match(req).then(hit => {
      const jaringan = fetch(req).then(n => { if (n && (n.ok || n.type === 'opaque')) c.put(req, n.clone()); return n; }).catch(() => hit);
      return hit || jaringan;
    })));
  }
});
