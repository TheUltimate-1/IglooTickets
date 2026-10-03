/**
 * EventShield QR - Progressive Web App Service Worker
 * Enables 100% Offline Scanning, CDN Asset Caching, and Background Sync
 */

const CACHE_NAME = 'eventshield-v2.6.0';
const STATIC_ASSETS = [
    './',
    './index.html',
    './config.js',
    './manifest.json',
    './icon.svg'
];

const CDN_ALLOWLIST = [
    'cdn.tailwindcss.com',
    'cdnjs.cloudflare.com',
    'cdn.jsdelivr.net',
    'fonts.googleapis.com',
    'fonts.gstatic.com'
];

// 1. Install Event: Cache Core Static Shell
self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(CACHE_NAME).then((cache) => {
            console.log('[ServiceWorker] Pre-caching offline application shell');
            return cache.addAll(STATIC_ASSETS);
        }).then(() => self.skipWaiting())
    );
});

// 2. Activate Event: Clean up outdated cache versions
self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys().then((cacheNames) => {
            return Promise.all(
                cacheNames.map((cacheName) => {
                    if (cacheName !== CACHE_NAME) {
                        console.log('[ServiceWorker] Removing stale cache:', cacheName);
                        return caches.delete(cacheName);
                    }
                })
            );
        }).then(() => self.clients.claim())
    );
});

// 3. Fetch Event: Network-First for HTML/Config; Stale-While-Revalidate for CDNs; Cache-First for static
self.addEventListener('fetch', (event) => {
    const url = new URL(event.request.url);

    // Bypass non-GET requests or Supabase REST/Realtime websocket requests
    if (event.request.method !== 'GET' || url.hostname.includes('supabase.co')) {
        return;
    }

    // A. Local HTML and Config: Network-First with Cache Fallback
    if (url.origin === location.origin) {
        event.respondWith(
            fetch(event.request)
                .then((networkResponse) => {
                    if (networkResponse && networkResponse.status === 200) {
                        const responseClone = networkResponse.clone();
                        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, responseClone));
                    }
                    return networkResponse;
                })
                .catch(() => {
                    return caches.match(event.request, { ignoreSearch: true }).then((cachedResponse) => {
                        if (cachedResponse) return cachedResponse;
                        if (event.request.mode === 'navigate') {
                            return caches.match('./index.html', { ignoreSearch: true });
                        }
                    });
                })
        );
        return;
    }

    // B. CDN Resources (Tailwind, FontAwesome, jsQR, etc.): Cache-First with Background Revalidation
    const isCdn = CDN_ALLOWLIST.some(cdnDomain => url.hostname.includes(cdnDomain));
    if (isCdn) {
        event.respondWith(
            caches.match(event.request).then((cachedResponse) => {
                const fetchPromise = fetch(event.request).then((networkResponse) => {
                    if (networkResponse && networkResponse.status === 200) {
                        const responseClone = networkResponse.clone();
                        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, responseClone));
                    }
                    return networkResponse;
                }).catch((err) => {
                    // Ignore network failure when offline
                });

                return cachedResponse || fetchPromise;
            })
        );
        return;
    }

    // Default: Fetch with fallback to cache
    event.respondWith(
        fetch(event.request).catch(() => caches.match(event.request))
    );
});
