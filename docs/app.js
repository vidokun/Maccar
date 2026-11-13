/* Maccar landing page behavior: theme, language, release hydration, copy, tabs. */
(function () {
  'use strict';

  var FALLBACK_VERSION = '1.4.0';
  var MANIFEST_PATH = './manifest.json';
  var RELEASE_API = 'https://api.github.com/repos/vidokun/Maccar/releases/latest';
  var REPO_URL = 'https://github.com/vidokun/Maccar';
  var CANONICAL = 'https://vidokun.github.io/Maccar/';
  var STORAGE_KEY = 'maccar.landing';
  var SUPPORT_LINKS = { trakteer: 'https://trakteer.id/vidokun/tip', sponsors: '', kofi: '', bmc: '' };

  // Each entry is [English, Bahasa Indonesia]; a missing ID string falls back to English.
  var TEXT = {
    'theme.label': ['Theme', 'Tema'],
    'hero.badge': ['Headless Sidecar for macOS 14+', 'Sidecar headless untuk macOS 14+'],
    'hero.title': ['Running a headless Mac mini without a monitor? Turn your iPad into a primary Retina display.', 'Mac mini tanpa monitor bikin Sidecar nggak bisa nyala? Colok iPad kamu, langsung jadi layar Retina utama.'],
    'hero.subtitle': ['Apple needs a display before Sidecar will start. Maccar creates a Retina screen in macOS memory instead, so your iPad connects over USB-C or Wi-Fi with no HDMI dummy plug.', 'macOS butuh layar sebelum Sidecar mau jalan. Maccar bikin layar Retina di memori macOS, jadi iPad langsung kebaca lewat USB-C atau Wi-Fi tanpa colokan HDMI dummy.'],
    'hero.dmg': ['Download Maccar v{version} (.dmg)', 'Unduh Maccar v{version} (.dmg)'],
    'hero.cli': ['Install from Terminal', 'Pasang lewat Terminal'],
    'status.loading': ['Checking for the latest release...', 'Sedang cek rilis terbaru...'],
    'status.ready': ['Latest release v{version}, verified by SHA-256', 'Rilis terbaru v{version}, sudah dicek pakai SHA-256'],
    'alert.text': ['Release lookup is unavailable right now. The v{version} download below is still verified.', 'Pengecekan rilis sedang gagal. Unduhan v{version} di bawah tetap terverifikasi.'],
    'alert.retry': ['Retry', 'Coba lagi'],
    'alert.link': ['Get v{version}', 'Ambil v{version}'],
    'install.title': ['Two ways to install, both verified', 'Dua cara pasang, dua-duanya terverifikasi'],
    'install.lead': ['The installer checks macOS 14+, the SHA-256 digest, and the code signature before it touches /Applications.', 'Skrip pemasang mengecek macOS 14+, digest SHA-256, dan tanda tangan kode sebelum menyentuh /Applications.'],
    'copy.label': ['Copy', 'Salin'],
    'copy.aria': ['Copy installer command', 'Salin perintah pemasangan'],
    'copy.done': ['Copied!', 'Tersalin!'],
    'install.cli.title': ['One-line terminal installer', 'Pemasang terminal satu baris'],
    'install.cli.text': ['No Xcode and no Command Line Tools. Add --dry-run to preview the checks, --version to pin a release, or --prefix to pick another folder.', 'Tanpa Xcode, tanpa Command Line Tools. Tambahkan --dry-run buat lihat pengecekan, --version buat pilih versi, atau --prefix buat ganti folder tujuan.'],
    'install.dmg.title': ['Disk image', 'File disk image'],
    'install.dmg.text': ['Open the image, drag Maccar.app into Applications, then launch it. Later releases arrive through Check for Updates in the menu bar.', 'Buka image, geser Maccar.app ke Applications, lalu jalankan. Rilis berikutnya masuk lewat Check for Updates di menu bar.'],
    'install.dmg.cta': ['Download Maccar-v{version}.dmg', 'Unduh Maccar-v{version}.dmg'],
    'shots.title': ['What it looks like on the Mac', 'Tampilannya di Mac seperti ini'],
    'shots.lead': ['Menu bar controls, the about window, and rotating diagnostics.', 'Kontrol menu bar, jendela about, dan log diagnosa yang berputar.'],
    'tab.menubar': ['Menu bar', 'Menu bar'],
    'tab.about': ['About', 'About'],
    'tab.logs': ['Diagnostics', 'Diagnosa'],
    'shot.menubar': ['Status, resolution presets, and update controls in one menu.', 'Status, preset resolusi, dan kontrol update dalam satu menu.'],
    'shot.about': ['Version, attribution, and the GPL-3.0 notice.', 'Versi, kredit, dan pemberitahuan GPL-3.0.'],
    'shot.logs': ['Rotating logs, capped at 512 KB on disk.', 'Log berputar dengan batas 512 KB di disk.'],
    'features.title': ['Built for a Mac mini with no keyboard and no monitor', 'Dirancang buat Mac mini tanpa keyboard dan tanpa monitor'],
    'features.one.title': ['No dummy hardware', 'Tanpa hardware dummy'],
    'features.one.text': ['CGVirtualDisplay allocates a Retina screen in memory, so Sidecar finds a display to extend or mirror.', 'CGVirtualDisplay bikin layar Retina di memori, jadi Sidecar menemukan layar buat extend atau mirror.'],
    'features.two.title': ['Survives sleep and unplug', 'Tahan tidur dan cabut kabel'],
    'features.two.text': ['A 750 ms USB attach hook wakes the session again, while repeated -200 failures back off instead of storming.', 'Hook USB 750 ms membangunkan sesi lagi, sementara kegagalan -200 berulang menunggu dulu alih-alih menumpuk.'],
    'features.three.title': ['Updates stay verified', 'Update tetap terverifikasi'],
    'features.three.text': ['Check for Updates validates the manifest, the SHA-256 digest, the bundle identifier, and the code signature before staging.', 'Check for Updates memeriksa manifest, digest SHA-256, bundle identifier, dan tanda tangan kode sebelum menyiapkan update.'],
    'donate.title': ['Donate & Support', 'Donasi & Dukungan'],
    'donate.lead': ['Maccar is free and GPL-3.0. If it saved you a dummy plug purchase, you can chip in for the next release.', 'Maccar gratis dan berlisensi GPL-3.0. Kalau aplikasi ini menghemat pembelian colokan dummy, kamu bisa ikut mendukung rilis berikutnya.'],
    'donate.active': ['Available now', 'Sudah tersedia'],
    'donate.trakteer.cta': ['Send a tip', 'Kirim tip'],
    'donate.soon': ['Coming soon', 'Segera hadir'],
    'donate.soon.cta': ['Not open yet', 'Belum dibuka'],
    'credits.title': ['Credits', 'Kredit'],
    'credits.lead': ['Maccar stands on public CoreGraphics and Sidecar research from the macOS community.', 'Maccar berdiri di atas riset CoreGraphics dan Sidecar yang publik dari komunitas macOS.'],
    'credit.sill': ['Apple Silicon headless virtual display and iPad workflow.', 'Alur kerja layar virtual headless dan iPad di Apple Silicon.'],
    'credit.vdisplay': ['Private CGVirtualDisplay bridging patterns.', 'Pola jembatan CGVirtualDisplay privat.'],
    'credit.sidecar': ['SidecarCore framework exploration and SidecarLauncher.', 'Eksplorasi framework SidecarCore dan SidecarLauncher.'],
    'footer.tagline': ['Maccar is free software under the GNU General Public License v3.0.', 'Maccar adalah perangkat lunak bebas di bawah GNU General Public License v3.0.'],
    'footer.license': ['License', 'Lisensi'],
    'footer.author': ['Built by Vido Rizki', 'Dibuat oleh Vido Rizki']
  };
  var TITLES = { en: 'Maccar: Headless Sidecar, iPad as a Primary Retina Display', id: 'Maccar: Sidecar tanpa monitor, iPad jadi layar Retina utama' };
  var DESCRIPTIONS = {
    en: 'Maccar creates a Retina virtual display in macOS memory so a headless Mac mini can run Sidecar on an iPad without an HDMI dummy plug.',
    id: 'Maccar bikin layar Retina virtual di memori macOS, jadi Mac mini headless bisa menjalankan Sidecar di iPad tanpa colokan HDMI dummy.'
  };

  var state = { lang: 'en', theme: 'system', version: FALLBACK_VERSION };

  function readStorage() {
    try {
      return JSON.parse(window.localStorage.getItem(STORAGE_KEY) || '{}') || {};
    } catch (error) {
      return {}; // Private windows and blocked site data must not break rendering.
    }
  }

  function writeStorage(patch) {
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(Object.assign(readStorage(), patch)));
    } catch (error) {
      /* Preferences are a convenience; a blocked write must never surface. */
    }
  }

  function t(key) {
    var entry = TEXT[key];
    if (!entry) return '';
    var value = (state.lang === 'id' ? entry[1] : entry[0]) || entry[0];
    return value.replace(/\{version\}/g, state.version);
  }

  function downloadUrl() {
    return REPO_URL + '/releases/download/v' + state.version + '/Maccar-v' + state.version + '.dmg';
  }

  function applyLanguage() {
    document.documentElement.setAttribute('lang', state.lang);
    document.title = TITLES[state.lang];
    var description = document.querySelector('meta[name="description"]');
    if (description) description.setAttribute('content', DESCRIPTIONS[state.lang]);
    var canonical = document.querySelector('link[rel="canonical"]');
    if (canonical) canonical.setAttribute('href', CANONICAL);
    document.querySelectorAll('[data-i18n]').forEach(function (node) {
      var text = t(node.getAttribute('data-i18n'));
      if (text) node.textContent = text;
    });
    document.querySelectorAll('[data-i18n-label]').forEach(function (node) {
      var label = t(node.getAttribute('data-i18n-label'));
      if (label) node.setAttribute(node.hasAttribute('alt') ? 'alt' : 'aria-label', label);
    });
    document.querySelectorAll('.lang-btn').forEach(function (button) {
      button.setAttribute('aria-pressed', String(button.getAttribute('data-lang') === state.lang));
    });
    document.querySelectorAll('a[data-download-link]').forEach(function (link) {
      link.setAttribute('href', downloadUrl());
    });
  }

  // 'system' follows the OS; everything else is an explicit visitor choice.
  function systemPrefersDark() {
    return typeof window.matchMedia === 'function' && window.matchMedia('(prefers-color-scheme: dark)').matches;
  }

  // The theme actually on screen right now. The toggle must compare against this rather
  // than against state.theme: choosing 'system' resolves to dark or light via CSS, so
  // toggling from the raw state would produce a click that changes nothing on screen.
  function resolvedTheme() {
    if (state.theme === 'dark' || state.theme === 'light') return state.theme;
    return systemPrefersDark() ? 'dark' : 'light';
  }

  function applyTheme() {
    var root = document.documentElement;
    if (state.theme === 'light' || state.theme === 'dark') root.setAttribute('data-theme', state.theme);
    else root.removeAttribute('data-theme');
    var toggle = document.querySelector('[data-theme-toggle]');
    if (!toggle) return;
    var isDark = resolvedTheme() === 'dark';
    toggle.setAttribute('aria-pressed', String(isDark));
    toggle.textContent = t('theme.label') + (isDark ? ' ☾' : ' ☀');
  }

  function setStatus(message, busy) {
    var node = document.querySelector('[data-release-status]');
    if (!node) return;
    node.textContent = message;
    if (busy) node.setAttribute('aria-busy', 'true');
    else node.removeAttribute('aria-busy');
  }

  function showAlert(visible) {
    var alert = document.querySelector('[data-release-alert]');
    if (alert) alert.hidden = !visible;
  }

  function bindDownload(url) {
    if (typeof url !== 'string' || !url) return;
    document.querySelectorAll('a[data-download-link]').forEach(function (link) {
      link.setAttribute('href', url);
    });
  }

  function parseVersion(value) {
    var match = String(value || '').match(/v?(\d+\.\d+\.\d+)/);
    return match ? match[1] : '';
  }

  function fromManifest(payload) {
    if (!payload || payload.product !== 'Maccar') return '';
    bindDownload(payload.artifacts && payload.artifacts.dmg && payload.artifacts.dmg.url);
    return parseVersion(payload.version);
  }

  function fromGitHubRelease(payload) {
    if (!payload || typeof payload.tag_name !== 'string') return '';
    var assets = Array.isArray(payload.assets) ? payload.assets : [];
    var dmg = assets.find(function (asset) {
      return typeof asset.name === 'string' && /\.dmg$/.test(asset.name);
    });
    if (dmg) bindDownload(dmg.browser_download_url);
    return parseVersion(payload.tag_name);
  }

  function fetchJson(url) {
    return window.fetch(url, { cache: 'no-store', headers: { Accept: 'application/json' } }).then(function (response) {
      if (!response.ok) throw new Error('HTTP ' + response.status);
      return response.json();
    });
  }

  function settle(version) {
    if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error('no release version');
    state.version = version;
    applyLanguage();
    setStatus(t('status.ready'), false);
    showAlert(false);
  }

  // A missing or blocked ./manifest.json falls back to the CORS-enabled GitHub API,
  // never to releases/latest/download (that redirect has no CORS headers).
  function hydrateRelease() {
    setStatus(t('status.loading'), true);
    fetchJson(MANIFEST_PATH)
      .then(fromManifest)
      .catch(function () {
        return fetchJson(RELEASE_API).then(fromGitHubRelease);
      })
      .then(settle)
      .catch(function () {
        state.version = FALLBACK_VERSION;
        applyLanguage();
        setStatus(t('status.ready'), false);
        showAlert(true);
      });
  }

  function setupTheme() {
    document.querySelectorAll('[data-theme-toggle]').forEach(function (button) {
      button.addEventListener('click', function () {
        // Flip away from what the visitor currently sees, not from the stored preference.
        state.theme = resolvedTheme() === 'dark' ? 'light' : 'dark';
        writeStorage({ theme: state.theme });
        applyTheme();
      });
    });
    // While following the OS, keep the glyph and aria-pressed honest if the OS switches.
    if (typeof window.matchMedia !== 'function') return;
    var query = window.matchMedia('(prefers-color-scheme: dark)');
    if (typeof query.addEventListener !== 'function') return;
    query.addEventListener('change', function () {
      if (state.theme === 'system') applyTheme();
    });
  }

  function setupLanguage() {
    document.querySelectorAll('.lang-btn').forEach(function (button) {
      button.addEventListener('click', function () {
        var next = button.getAttribute('data-lang');
        if (next !== 'en' && next !== 'id') return;
        state.lang = next;
        writeStorage({ lang: next });
        applyLanguage();
        applyTheme();
        setStatus(t('status.ready'), false);
      });
    });
  }

  function setupCopy() {
    document.querySelectorAll('[data-copy-target]').forEach(function (button) {
      button.addEventListener('click', function () {
        var target = document.getElementById(button.getAttribute('data-copy-target'));
        if (!target) return;
        var done = function () {
          button.classList.add('is-copied');
          button.textContent = t('copy.done');
          window.setTimeout(function () {
            button.classList.remove('is-copied');
            button.textContent = t('copy.label');
          }, 1600);
        };
        if (!navigator.clipboard || !navigator.clipboard.writeText) {
          done();
          return;
        }
        navigator.clipboard.writeText(target.textContent.trim()).then(done).catch(done);
      });
    });
  }

  function setupTabs() {
    var tabs = Array.prototype.slice.call(document.querySelectorAll('.tab-btn[role="tab"]'));
    if (!tabs.length) return;
    function select(tab) {
      tabs.forEach(function (item) {
        var active = item === tab;
        item.setAttribute('aria-selected', String(active));
        item.tabIndex = active ? 0 : -1;
        var panel = document.getElementById(item.getAttribute('aria-controls'));
        if (panel) panel.hidden = !active;
      });
    }
    tabs.forEach(function (tab, index) {
      tab.addEventListener('click', function () {
        select(tab);
      });
      tab.addEventListener('keydown', function (event) {
        var step = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0;
        if (!step) return;
        event.preventDefault();
        var next = tabs[(index + step + tabs.length) % tabs.length];
        select(next);
        next.focus();
      });
    });
  }

  function setupSupport() {
    document.querySelectorAll('[data-support]').forEach(function (card) {
      var url = SUPPORT_LINKS[card.getAttribute('data-support')];
      if (url) {
        card.classList.remove('is-disabled');
        card.removeAttribute('aria-disabled');
        if (card.tagName === 'A') card.setAttribute('href', url);
        return;
      }
      card.classList.add('is-disabled');
      card.setAttribute('aria-disabled', 'true');
      if (card.tagName === 'A') card.removeAttribute('href');
    });
  }

  function setupRetry() {
    document.querySelectorAll('[data-retry]').forEach(function (button) {
      button.addEventListener('click', function () {
        showAlert(false);
        hydrateRelease();
      });
    });
  }

  function boot() {
    var stored = readStorage();
    state.lang = stored.lang === 'id' ? 'id' : 'en';
    state.theme = stored.theme === 'dark' || stored.theme === 'light' ? stored.theme : 'system';
    setupTheme();
    setupLanguage();
    setupCopy();
    setupTabs();
    setupSupport();
    setupRetry();
    applyLanguage();
    applyTheme();
    hydrateRelease();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
