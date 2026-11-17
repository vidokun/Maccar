/* Maccar landing page behavior: theme, language, release hydration, copy, tabs. */
(function () {
  'use strict';

  var FALLBACK_VERSION = '1.4.2';
  var MANIFEST_PATH = './manifest.json';
  var RELEASE_API = 'https://api.github.com/repos/vidokun/Maccar/releases/latest';
  var REPO_URL = 'https://github.com/vidokun/Maccar';
  var CANONICAL = 'https://vidokun.github.io/Maccar/';
  var STORAGE_KEY = 'maccar.landing';
  var SUPPORT_LINKS = { trakteer: 'https://trakteer.id/vidokun/tip', sponsors: '', kofi: '', bmc: '' };

  // Each entry is [English, Bahasa Indonesia]; a missing ID string falls back to English.
  var TEXT = {
    'theme.label': ['Switch between light and dark theme', 'Ganti tema terang dan gelap'],
    'nav.how': ['How it works', 'Cara kerjanya'],
    'nav.install': ['Install', 'Pasang'],
    'nav.compare': ['Compare', 'Bandingkan'],
    'nav.faq': ['FAQ', 'Tanya jawab'],
    'nav.support': ['Support', 'Dukungan'],
    'nav.open': ['Open menu', 'Buka menu'],
    'nav.close': ['Close menu', 'Tutup menu'],
    'hero.badge': ['No monitor · No dummy plug · One iPad', 'Tanpa monitor · Tanpa colokan dummy · Cukup iPad'],
    'hero.title': ['Turn an iPad into the main monitor of a <span class="hero-title-accent">headless Mac mini</span>.', 'Jadikan iPad sebagai <span class="hero-title-accent">monitor utama</span> Mac mini headless Anda.'],
    'hero.subtitle': ['macOS wants a screen before Sidecar will start — that is the whole reason a Mac mini with no monitor needs an HDMI dummy plug. Maccar puts a Retina display in memory instead, so your iPad connects over USB-C or Wi-Fi and the Mac mini gets a real desktop again.', 'macOS menuntut ada layar dulu sebelum Sidecar mau jalan — itu akar masalah kenapa Mac mini tanpa monitor harus pakai colokan HDMI dummy. Maccar membuat layar Retina di memori, jadi iPad tersambung lewat USB-C atau Wi-Fi dan Mac mini Anda punya desktop lagi.'],
    'hero.dmg': ['Download Maccar v{version} (.dmg)', 'Unduh Maccar v{version} (.dmg)'],
    'hero.cli': ['Install from Terminal', 'Pasang lewat Terminal'],
    'status.loading': ['Checking for the latest release...', 'Sedang cek rilis terbaru...'],
    'status.ready': ['Latest release v{version}, verified by SHA-256', 'Rilis terbaru v{version}, sudah dicek pakai SHA-256'],
    'alert.text': ['Release lookup is unavailable right now. The v{version} download below is still verified.', 'Pengecekan rilis sedang gagal. Unduhan v{version} di bawah tetap terverifikasi.'],
    'alert.retry': ['Retry', 'Coba lagi'],
    'alert.link': ['Get v{version}', 'Ambil v{version}'],
    'install.eyebrow': ['Install', 'Pasang'],
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
    'donate.title': ['Maccar saved you a dummy plug. Buy it a coffee.', 'Maccar menghemat satu colokan dummy. Traktir kopi, yuk.'],
    'donate.lead': ['Maccar is free software under GPL-3.0 and always will be. No paywall, no license key, no upsell. A donation goes straight to the Apple Developer program and the notarization that keeps every download opening without a warning.', 'Maccar adalah perangkat lunak bebas berlisensi GPL-3.0, dan akan selalu begitu. Tanpa paywall, tanpa license key, tanpa upsell. Donasi Anda langsung ke program Apple Developer dan notarisasi yang membuat setiap unduhan terbuka tanpa peringatan.'],
    'donate.fine': ['There is no account to create and nothing to cancel. This button is the entire commercial relationship.', 'Tidak ada akun yang harus dibuat dan tidak ada yang perlu dibatalkan. Tombol ini adalah keseluruhan hubungan komersialnya.'],
    'donate.cta': ['Support on Trakteer', 'Dukung lewat Trakteer'],
    'donate.note': ['Opens trakteer.id in a new tab', 'Terbuka di tab baru, trakteer.id'],
    'donate.source': ['Or star the repo instead', 'Atau beri bintang di repo saja'],
    'credits.title': ['Credits', 'Kredit'],
    'credits.lead': ['Maccar stands on public CoreGraphics and Sidecar research from the macOS community.', 'Maccar berdiri di atas riset CoreGraphics dan Sidecar yang publik dari komunitas macOS.'],
    'credit.sill': ['Apple Silicon headless virtual display and iPad workflow.', 'Alur kerja layar virtual headless dan iPad di Apple Silicon.'],
    'credit.vdisplay': ['Private CGVirtualDisplay bridging patterns.', 'Pola jembatan CGVirtualDisplay privat.'],
    'credit.sidecar': ['SidecarCore framework exploration and SidecarLauncher.', 'Eksplorasi framework SidecarCore dan SidecarLauncher.'],
    'footer.tagline': ['Maccar is free software under the GNU General Public License v3.0.', 'Maccar adalah perangkat lunak bebas di bawah GNU General Public License v3.0.'],
    'footer.license': ['License', 'Lisensi'],
    'footer.author': ['Built by Vido Rizki', 'Dibuat oleh Vido Rizki'],

    // --- Hero extras ---
    'hero.meta.trust': ['Notarized by Apple · GPL-3.0 · Free', 'Dinotarisasi Apple · GPL-3.0 · Gratis'],
    'hero.chip.retina': ['Retina · 1440×946', 'Retina · 1440×946'],
    'hero.chip.usb': ['USB-C attach detected', 'USB-C terdeteksi'],

    // --- The problem ---
    'problem.eyebrow': ['The problem', 'Masalahnya'],
    'problem.title': ['A Mac mini with no monitor cannot start Sidecar', 'Mac mini tanpa monitor tidak bisa menjalankan Sidecar'],
    'problem.lead': ['macOS wants a display before it will hand a screen to Sidecar. That single requirement is what sends people looking for a dummy HDMI plug — and why an iPad alone is not enough out of the box.', 'macOS minta ada layar dulu sebelum mau menyerahkan layar ke Sidecar. Aturan tunggal itulah yang bikin orang mencari colokan HDMI dummy — dan kenapa iPad saja belum cukup dari awal.'],
    'problem.one.title': ['The display requirement', 'Syarat harus ada layar'],
    'problem.one.text': ['Sidecar extends a display. With nothing attached, there is nothing to extend, so the connection never becomes available — even though the iPad is sitting right there.', 'Sidecar memperluas layar. Kalau tidak ada yang terpasang, tidak ada yang bisa diperluas, jadi koneksinya tidak pernah tersedia — padahal iPad-nya ada di situ.'],
    'problem.two.title': ['The dummy plug tax', 'Biaya colokan dummy'],
    'problem.two.text': ['The usual workaround is a headless HDMI adapter that pretends to be a monitor. It works, but it costs money, occupies a port, and adds one more thing that can fail silently.', 'Solusi biasanya colokan HDMI headless yang berpura-pura jadi monitor. Bisa jalan, tapi bayar, makan satu port, dan menambah satu lagi bagian yang bisa rusak diam-diam.'],
    'problem.three.title': ['The reconnection loop', 'Lingkaran gagal menyambung'],
    'problem.three.text': ['Even with a display present, a sleeping or unplugged iPad turns into a stream of failed connection attempts. Without a deliberate retry model the app turns into an alert generator.', 'Walau layarnya ada, iPad yang tidur atau kabelnya lepas berubah jadi deretan percobaan koneksi yang gagal. Tanpa aturan retry yang jelas, aplikasi berubah jadi pabrik notifikasi.'],

    // --- How it works ---
    'how.eyebrow': ['How it works', 'Cara kerjanya'],
    'how.title': ['A Retina display that exists only in memory', 'Layar Retina yang hanya ada di memori'],
    'how.lead': ['No hardware, no virtual machine, no second Mac. Maccar asks macOS for a display object, waits until the system treats it as usable, then lets Sidecar do its job.', 'Tanpa hardware, tanpa virtual machine, tanpa Mac kedua. Maccar meminta objek layar ke macOS, menunggu sampai sistem menganggapnya layak pakai, lalu membiarkan Sidecar bekerja.'],
    'how.one.title': ['Allocate the virtual display', 'Membuat layar virtual'],
    'how.one.text': ['Maccar creates a CGVirtualDisplay in memory with a Retina-class resolution. macOS registers it exactly like a monitor, so every window server API behaves normally.', 'Maccar membuat CGVirtualDisplay di memori dengan resolusi kelas Retina. macOS mendaftarkannya persis seperti monitor, jadi semua API window server berperilaku normal.'],
    'how.two.title': ['Verify and switch resolution in place', 'Verifikasi dan ganti resolusi di tempat'],
    'how.two.text': ['Each mode is checked with CGDisplayModeIsUsableForDesktopGUI before it is offered, then applied with CGConfigureDisplayWithDisplayMode so an active iPad session is not torn down by a resolution change.', 'Setiap mode diced dengan CGDisplayModeIsUsableForDesktopGUI sebelum ditawarkan, lalu dipasang lewat CGConfigureDisplayWithDisplayMode supaya sesi iPad yang aktif tidak terputus gara-gara ganti resolusi.'],
    'how.three.title': ['Connect the iPad through Sidecar', 'Menyambungkan iPad lewat Sidecar'],
    'how.three.text': ['With a usable display present, Maccar asks Sidecar to connect to your registered iPad over USB-C or Wi-Fi, then mirrors the iPad onto the virtual screen so the Mac mini has a primary display again.', 'Karena sudah ada layar yang layak pakai, Maccar meminta Sidecar menyambung ke iPad terdaftar lewat USB-C atau Wi-Fi, lalu me-mirror iPad ke layar virtual supaya Mac mini punya layar utama lagi.'],
    'how.four.title': ['Hold on through sleep, unplug and lid close', 'Bertahan saat tidur, kabel lepas, dan ditutup'],
    'how.four.text': ['A USB attach hook notices the cable coming back, a presence check makes sure the iPad is really there before connecting, and failures are classified so one transient hiccup does not disable automatic recovery.', 'Hook USB mendeteksi kabel masuk lagi, pengecekan presence memastikan iPad benar-benar ada sebelum menyambung, dan jenis kegagalan dibedakan supaya satu gangguan sesaat tidak mematikan pemulihan otomatis.'],

    // --- Compare ---
    'compare.eyebrow': ['Compare', 'Perbandingan'],
    'compare.title': ['Against the ways people solve this today', 'Dibanding cara yang dipakai orang sekarang'],
    'compare.lead': ['A dummy plug works. Buying a monitor works. Both cost money and neither reconnects for you.', 'Colokan dummy bisa. Beli monitor juga bisa. Dua-duanya keluar uang dan tidak ada yang menyambung ulang sendiri.'],
    'compare.col.approach': ['Approach', 'Cara'],
    'compare.col.cost': ['Extra hardware', 'Hardware tambahan'],
    'compare.col.screen': ['Actual screen', 'Layar sungguhan'],
    'compare.col.auto': ['Reconnects itself', 'Menyambung sendiri'],
    'compare.row.dummy': ['HDMI dummy plug', 'Colokan HDMI dummy'],
    'compare.row.monitor': ['Spare monitor', 'Monitor cadangan'],
    'compare.row.vnc': ['Headless VNC only', 'Hanya VNC headless'],
    'compare.req.adapter': ['An adapter', 'Satu adapter'],
    'compare.req.monitor': ['A whole display', 'Satu monitor penuh'],
    'compare.none': ['None', 'Tidak ada'],
    'compare.yes': ['Yes', 'Ya'],
    'compare.no': ['No', 'Tidak'],

    // --- Gallery ---
    'shots.eyebrow': ['Gallery', 'Galeri'],

    // --- Features extras ---
    'features.eyebrow': ['Features', 'Fitur'],
    'features.lead': ['Every one of these exists because a headless machine cannot ask a human to click something.', 'Semua ini ada karena mesin headless tidak bisa minta manusia mengklik sesuatu.'],
    'features.four.title': ['Several iPads, told apart properly', 'Beberapa iPad, dibedakan dengan benar'],
    'features.four.text': ['Devices are keyed on Sidecar\'s stable identifier, not their name. Two iPads called the same thing stay distinct, and renaming one cannot retarget the app.', 'Perangkat dikenali dari identifier stabil Sidecar, bukan namanya. Dua iPad bernama sama tetap berbeda, dan mengganti nama salah satunya tidak membelokkan aplikasi.'],
    'features.five.title': ['Presets that cannot fail', 'Preset yang tidak mungkin gagal'],
    'features.five.text': ['Resolutions the active display cannot actually use are filtered out of the menu, so a preset never appears only to fail when clicked.', 'Resolusi yang tidak benar-benar bisa dipakai layar aktif disaring keluar dari menu, jadi tidak ada preset yang muncul lalu gagal saat diklik.'],
    'features.six.title': ['Diagnostics you can paste', 'Diagnosa yang bisa langsung ditempel'],
    'features.six.text': ['Copy Diagnostics puts version, macOS build, launch-at-login state, connected iPads and the log path on the clipboard — with your home folder shortened to ~/.', 'Copy Diagnostics menaruh versi, build macOS, status launch-at-login, iPad terhubung, dan lokasi log ke clipboard — dengan folder home dipersingkat jadi ~/.'],

    // --- Stats ---
    'stats.presets': ['Virtual display presets', 'Preset layar virtual'],
    'stats.logcap': ['Rotating log cap', 'Batas log berputar'],
    'stats.price': ['Price, forever', 'Harga, selamanya'],
    'stats.notarized': ['Releases notarized', 'Rilis dinotarisasi'],

    // --- Use cases ---
    'uses.eyebrow': ['Who this is for', 'Untuk siapa'],
    'uses.title': ['Setups where a monitor is a nuisance', 'Setup yang justru repot kalau pakai monitor'],
    'uses.one.title': ['The headless home server', 'Server rumah tanpa layar'],
    'uses.one.text': ['A Mac mini in a cupboard running builds, backups or media. You want to look at it from an iPad on the sofa, not carry a monitor to it.', 'Mac mini di lemari yang menjalankan build, backup, atau media. Kamu mau melihatnya dari iPad di sofa, bukan menggotong monitor ke situ.'],
    'uses.two.title': ['The travelling desk', 'Meja kerja keliling'],
    'uses.two.text': ['A Mac mini in a bag and an iPad in a case. Nothing else. Maccar turns that into a complete computer with one cable.', 'Mac mini di tas dan iPad di sarungnya. Tidak ada yang lain. Maccar mengubahnya jadi komputer lengkap dengan satu kabel.'],
    'uses.three.title': ['The kiosk and demo Mac', 'Mac untuk kios dan demo'],
    'uses.three.text': ['A machine that must boot and show something without anyone attaching a screen. The virtual display is there from the start.', 'Mesin yang harus menyala dan menampilkan sesuatu tanpa ada yang memasang layar. Layar virtualnya sudah ada sejak awal.'],
    'uses.four.title': ['The second Mac you rarely touch', 'Mac kedua yang jarang disentuh'],
    'uses.four.text': ['A build machine that only needs a screen twice a week. Maccar gives it one on demand and gets out of the way when you unplug.', 'Mesin build yang cuma butuh layar dua kali seminggu. Maccar memberinya layar saat dibutuhkan dan menyingkir begitu kabel dilepas.'],

    // --- FAQ ---
    'faq.eyebrow': ['FAQ', 'Tanya jawab'],
    'faq.title': ['Questions people actually ask', 'Pertanyaan yang benar-benar ditanya'],
    'faq.one.q': ['Does Maccar let me use Sidecar on a Mac mini with no monitor attached?', 'Apakah Maccar membuat Sidecar jalan di Mac mini tanpa monitor?'],
    'faq.one.a': ['Yes. Apple requires an active display before Sidecar will start, which is why a headless Mac mini normally needs an HDMI dummy plug. Maccar creates a Retina virtual display in macOS memory instead, so Sidecar sees a real display and your iPad connects over USB-C or Wi-Fi.', 'Ya. Apple minta ada layar aktif sebelum Sidecar mau jalan, itu sebabnya Mac mini headless biasanya butuh colokan HDMI dummy. Maccar membuat layar Retina virtual di memori macOS, jadi Sidecar melihat layar sungguhan dan iPad tersambung lewat USB-C atau Wi-Fi.'],
    'faq.two.q': ['Do I still need an HDMI dummy plug with Maccar?', 'Apakah masih perlu colokan HDMI dummy kalau pakai Maccar?'],
    'faq.two.a': ['No. Maccar replaces the dummy plug with a CGVirtualDisplay allocated in software. Nothing needs to be plugged into the HDMI port, and nothing extra needs to be bought.', 'Tidak. Maccar menggantikan colokan dummy dengan CGVirtualDisplay yang dibuat di software. Tidak ada yang perlu dicolok ke port HDMI, dan tidak ada yang perlu dibeli.'],
    'faq.three.q': ['Which macOS versions and Macs are supported?', 'macOS dan Mac apa yang didukung?'],
    'faq.three.a': ['macOS 14.0 or newer. Maccar uses CGVirtualDisplay plus SidecarCore, so it works on both Apple Silicon and Intel Macs that can run macOS 14.', 'macOS 14.0 atau lebih baru. Maccar memakai CGVirtualDisplay dan SidecarCore, jadi jalan di Mac Apple Silicon maupun Intel yang bisa menjalankan macOS 14.'],
    'faq.four.q': ['Is Maccar signed and notarized, or will Gatekeeper block it?', 'Apakah Maccar ditandatangani dan dinotarisasi, atau diblokir Gatekeeper?'],
    'faq.four.a': ['Every release is signed with an Apple Developer ID certificate and notarized by Apple. macOS opens it on double-click without the cannot-be-verified warning, and each release publishes a SHA-256 checksum that the installer verifies before installing.', 'Setiap rilis ditandatangani sertifikat Apple Developer ID dan dinotarisasi Apple. macOS membukanya dengan klik dua kali tanpa peringatan tidak dapat diverifikasi, dan setiap rilis menyertakan checksum SHA-256 yang dicek installer sebelum memasang.'],
    'faq.five.q': ['Does Maccar connect over Wi-Fi as well as USB-C?', 'Apakah Maccar bisa lewat Wi-Fi selain USB-C?'],
    'faq.five.a': ['Both work, but USB-C is the reliable path for a headless setup. Maccar reacts to physical USB attach and checks that an iPad is actually present before it calls connect, so it never issues a connection for a device that is not there.', 'Dua-duanya bisa, tapi USB-C adalah jalur yang andal untuk setup headless. Maccar bereaksi pada colokan USB fisik dan mengecek iPad benar-benar ada sebelum memanggil connect, jadi tidak pernah menyambung ke perangkat yang tidak ada.'],
    'faq.six.q': ['Can I register more than one iPad?', 'Bisakah mendaftarkan lebih dari satu iPad?'],
    'faq.six.a': ['Yes. Devices are identified by Sidecar\'s stable identifier rather than their name, so two iPads with the same name stay distinct, renaming one does not retarget the app, and Forget genuinely removes it. Switching between registered iPads is an explicit Menu Bar action.', 'Bisa. Perangkat dikenali dari identifier stabil Sidecar, bukan namanya, jadi dua iPad bernama sama tetap berbeda, mengganti nama tidak membelokkan aplikasi, dan Forget benar-benar menghapusnya. Berpindah antar iPad dilakukan lewat Menu Bar secara sengaja.'],
    'faq.seven.q': ['Why does the first reconnect after unplugging still show one alert?', 'Kenapa sambungan pertama setelah cabut masih memunculkan satu notifikasi?'],
    'faq.seven.a': ['Sidecar restarts its display agent on every replug and refuses connections until that agent is ready. Maccar retries automatically and reconnects in about eight seconds without any manual step, but that first attempt can raise a single Sidecar alert. This is documented as a known limitation rather than hidden.', 'Sidecar menjalankan ulang display agent-nya setiap kali kabel dicolok dan menolak koneksi sampai agent itu siap. Maccar mencoba ulang otomatis dan tersambung dalam sekitar delapan detik tanpa langkah manual, tapi percobaan pertama itu bisa memunculkan satu notifikasi Sidecar. Ini dicatat sebagai keterbatasan yang diketahui, bukan disembunyikan.'],
    'faq.eight.q': ['Is Maccar free and open source?', 'Apakah Maccar gratis dan open source?'],
    'faq.eight.a': ['Yes. Maccar is free software under the GNU General Public License v3.0, and the full source is on GitHub.', 'Ya. Maccar adalah perangkat lunak bebas di bawah GNU General Public License v3.0, dan seluruh kodenya ada di GitHub.'],

    // --- Support / call ---
    'donate.eyebrow': ['Support', 'Dukungan'],
    'credits.eyebrow': ['Credits', 'Kredit'],
    'call.title': ['Give your Mac mini a screen without buying one', 'Beri Mac mini layar tanpa membelinya'],
    'call.text': ['Download the disk image, drag it to Applications, and plug in your iPad. The first launch needs no configuration.', 'Unduh disk image, geser ke Applications, lalu colok iPad. Peluncuran pertama tidak butuh konfigurasi apa pun.'],
    'call.cta': ['Download Maccar', 'Unduh Maccar'],
    'call.source': ['View the source', 'Lihat kodenya']
  };
  // Keep these in step with <title> and <meta name="description"> in index.html:
  // applyLanguage() overwrites both, so a stale copy here silently wins.
  var TITLES = {
    en: 'iPad as Monitor for a Headless Mac mini — Maccar',
    id: 'iPad Jadi Monitor Mac mini Headless — Maccar'
  };
  var DESCRIPTIONS = {
    en: 'Use your iPad as the only monitor for a headless Mac mini. Maccar creates a Retina virtual display in macOS memory, so Sidecar works with no HDMI dummy plug and no second screen. Free, notarized, macOS 14+.',
    id: 'Pakai iPad sebagai satu-satunya monitor Mac mini headless. Maccar membuat layar Retina virtual di memori macOS, jadi Sidecar jalan tanpa colokan HDMI dummy dan tanpa layar kedua. Gratis, dinotarisasi, macOS 14+.'
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
      if (!text) return;
      // Only strings that carry inline markup (the hero headline's accent span) opt in
      // to HTML. Every other node stays on textContent so translated copy can never
      // inject markup into the page.
      if (node.hasAttribute('data-i18n-html')) node.innerHTML = text;
      else node.textContent = text;
    });
    document.querySelectorAll('[data-i18n-label]').forEach(function (node) {
      var label = t(node.getAttribute('data-i18n-label'));
      if (label) node.setAttribute(node.hasAttribute('alt') ? 'alt' : 'aria-label', label);
    });
    document.querySelectorAll('.lang-btn').forEach(function (button) {
      button.setAttribute('aria-pressed', String(button.getAttribute('data-lang') === state.lang));
    });
    // The nav trigger's accessible name is translated copy, so it has to be
    // re-applied after a language switch, not only at setup.
    var navToggle = document.querySelector('[data-nav-toggle]');
    if (navToggle) {
      navToggle.setAttribute('aria-label', t(navToggle.getAttribute('aria-expanded') === 'true' ? 'nav.close' : 'nav.open'));
    }
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
    var isDark = resolvedTheme() === 'dark';
    var toggle = document.querySelector('[data-theme-toggle]');
    if (!toggle) return;
    toggle.setAttribute('aria-pressed', String(isDark));
    // The control is icon-only, so the glyph has to show what the next click does:
    // a sun means "switch to light", a moon means "switch to dark".
    var icon = toggle.querySelector('[data-theme-icon]');
    if (icon) icon.textContent = isDark ? '☀' : '☾';
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

  // There is exactly one open support channel. If its URL is ever emptied, the button
  // becomes a non-link rather than a dead anchor that looks clickable.
  function setupSupport() {
    document.querySelectorAll('[data-support]').forEach(function (node) {
      var url = SUPPORT_LINKS[node.getAttribute('data-support')];
      if (url) {
        node.setAttribute('href', url);
        node.classList.remove('is-disabled');
        node.removeAttribute('aria-disabled');
        return;
      }
      node.classList.add('is-disabled');
      node.setAttribute('aria-disabled', 'true');
      node.removeAttribute('href');
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

  // --------------------------------------------------------------- motion ---

  function prefersReducedMotion() {
    return typeof window.matchMedia === 'function' &&
      window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  }

  // Reveal on scroll. The CSS only hides .reveal when <html> carries .js-ready, so a
  // visitor without JS (or with it disabled) still sees every section.
  //
  // The fallback below is viewport-scoped on purpose. An earlier version revealed
  // *everything* once 1.5s passed with nothing yet visible, which is the normal state
  // on load here: the hero intentionally holds no .reveal elements, so the observer
  // has nothing to report until the visitor scrolls. That timer therefore re-showed
  // the whole page before the first scroll and silently disabled the animation.
  function setupScrollReveal() {
    var targets = Array.prototype.slice.call(document.querySelectorAll('.reveal'));
    if (!targets.length) return;

    function revealAll() {
      targets.forEach(function (node) { node.classList.add('is-visible'); });
    }

    if (prefersReducedMotion() || typeof window.IntersectionObserver !== 'function') {
      revealAll();
      return;
    }

    var observerFired = false;

    var observer = new IntersectionObserver(function (entries) {
      observerFired = true;
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
      });
    }, { rootMargin: '0px 0px -12% 0px', threshold: 0.08 });

    targets.forEach(function (node, index) {
      // Siblings reveal in sequence rather than all at once; capped so long grids
      // do not make the last card wait a full second.
      node.style.setProperty('--reveal-delay', Math.min(index % 6, 5) * 70 + 'ms');
      observer.observe(node);
    });

    // Anything already at or above the fold becomes visible immediately. This is
    // true whether or not the observer works, and it is what covers the case of a
    // page opened deep in its own history (a reload mid-scroll, or a #anchor).
    function revealInView() {
      var limit = window.innerHeight;
      targets.forEach(function (node) {
        if (node.classList.contains('is-visible')) return;
        if (node.getBoundingClientRect().top < limit) node.classList.add('is-visible');
      });
    }

    revealInView();

    // If the observer never fires, a scroll listener takes over so the page still
    // reveals as it is read instead of staying blank below the fold.
    window.setTimeout(function () {
      if (observerFired) return;
      window.addEventListener('scroll', revealInView, { passive: true });
    }, 1500);
  }

  // A pointer-driven 3D tilt on the hero mockup. Pointer-only on purpose: touch
  // devices should not get a card that jumps under their finger while scrolling.
  function setupTilt() {
    var stage = document.querySelector('[data-tilt]');
    if (!stage || prefersReducedMotion()) return;
    var card = stage.querySelector('.device-card');
    if (!card) return;

    var maxDegrees = 8;
    var frame = 0;

    function apply(event) {
      var rect = stage.getBoundingClientRect();
      var px = (event.clientX - rect.left) / rect.width;   // 0..1
      var py = (event.clientY - rect.top) / rect.height;   // 0..1
      var tiltY = (px - 0.5) * 2 * maxDegrees;
      var tiltX = (0.5 - py) * 2 * maxDegrees;
      card.style.setProperty('--tilt-x', tiltX.toFixed(2) + 'deg');
      card.style.setProperty('--tilt-y', tiltY.toFixed(2) + 'deg');
    }

    stage.addEventListener('pointermove', function (event) {
      if (event.pointerType === 'touch') return;
      if (frame) return;
      frame = window.requestAnimationFrame(function () {
        frame = 0;
        apply(event);
      });
    });

    stage.addEventListener('pointerleave', function () {
      card.style.setProperty('--tilt-x', '0deg');
      card.style.setProperty('--tilt-y', '0deg');
    });
  }

  // Numbers count up once, when they first scroll into view.
  function setupCounters() {
    var values = Array.prototype.slice.call(document.querySelectorAll('[data-count-to]'));
    if (!values.length) return;

    function settle(node) {
      var target = Number(node.getAttribute('data-count-to')) || 0;
      node.textContent = String(target) + (node.getAttribute('data-count-suffix') || '');
    }

    if (prefersReducedMotion() || typeof window.IntersectionObserver !== 'function') {
      values.forEach(settle);
      return;
    }

    // Same reasoning as setupScrollReveal: a counter left at 0 looks broken, so if the
    // observer never fires the numbers still arrive.
    window.setTimeout(function () {
      values.forEach(function (node) {
        if (node.textContent.trim() === '0' || node.textContent.trim() === '0%' || node.textContent.trim() === '0 KB') {
          settle(node);
        }
      });
    }, 2200);

    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        var node = entry.target;
        observer.unobserve(node);
        var target = Number(node.getAttribute('data-count-to')) || 0;
        var suffix = node.getAttribute('data-count-suffix') || '';
        var duration = 900;
        var started = 0;
        function step(timestamp) {
          if (!started) started = timestamp;
          var progress = Math.min(1, (timestamp - started) / duration);
          // Ease-out so the number decelerates into its final value.
          var eased = 1 - Math.pow(1 - progress, 3);
          node.textContent = String(Math.round(target * eased)) + suffix;
          if (progress < 1) window.requestAnimationFrame(step);
        }
        window.requestAnimationFrame(step);
      });
    }, { threshold: 0.4 });

    values.forEach(function (node) { observer.observe(node); });
  }

  // The sticky header grows a hairline border only once the page has moved.
  function setupHeaderState() {
    var header = document.querySelector('[data-header]');
    if (!header) return;
    function sync() {
      header.classList.toggle('is-scrolled', window.scrollY > 8);
    }
    sync();
    window.addEventListener('scroll', sync, { passive: true });
  }

  // The mobile menu panel. Opening is a class on the <nav> plus aria-expanded on
  // the trigger; the panel itself is only reachable while open because CSS toggles
  // visibility alongside max-height.
  function setupNav() {
    var toggle = document.querySelector('[data-nav-toggle]');
    var nav = document.querySelector('[data-nav]');
    if (!toggle || !nav) return;

    function setOpen(open) {
      nav.classList.toggle('is-open', open);
      toggle.setAttribute('aria-expanded', String(open));
      toggle.setAttribute('aria-label', t(open ? 'nav.close' : 'nav.open'));
    }

    toggle.addEventListener('click', function () {
      setOpen(toggle.getAttribute('aria-expanded') !== 'true');
    });

    // Following a link must close the panel, or it stays over the content the
    // visitor just asked for.
    nav.addEventListener('click', function (event) {
      if (event.target.closest('a')) setOpen(false);
    });

    document.addEventListener('keydown', function (event) {
      if (event.key !== 'Escape') return;
      if (toggle.getAttribute('aria-expanded') !== 'true') return;
      setOpen(false);
      toggle.focus();
    });
  }

  function boot() {
    var stored = readStorage();
    state.lang = stored.lang === 'id' ? 'id' : 'en';
    state.theme = stored.theme === 'dark' || stored.theme === 'light' ? stored.theme : 'system';
    // Marks that animation is available at all: CSS hides .reveal only under this class.
    document.documentElement.classList.add('js-ready');
    setupTheme();
    setupLanguage();
    setupNav();
    setupCopy();
    setupTabs();
    setupSupport();
    setupRetry();
    setupScrollReveal();
    setupTilt();
    setupCounters();
    setupHeaderState();
    applyLanguage();
    applyTheme();
    hydrateRelease();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
