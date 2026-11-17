# Deploying the Maccar landing page to Vercel

The landing page lives in `docs/`. Once the repository is connected to Vercel,
every push to `main` redeploys it — there is no build step to remember and no
second workflow to keep in sync.

## What makes the import automatic

`vercel.json` at the repository root is what tells Vercel this repo is a static
site whose published folder is `docs/`:

| Key | Value | Why it matters |
|---|---|---|
| `framework` | `null` | No framework preset is inferred from `Package.swift` |
| `buildCommand` | `node scripts/prepare-vercel-site.mjs` | Pulls the release manifest in at build time |
| `outputDirectory` | `docs` | Vercel serves the *contents* of `docs/` as the site root |
| `cleanUrls` | `true` | Serves extensionless URLs |
| `trailingSlash` | `false` | Keeps `/` canonical instead of `/index.html` |

Without `outputDirectory`, Vercel would publish the repository root and the
site would be a 404 with the Swift sources exposed. That single key is the
difference between working and broken.

## One-time import

1. Push this repository to GitHub with `vercel.json` committed (see the checklist
   at the end of this file).
2. Go to <https://vercel.com/new>.
3. Import the `Maccar` repository. Leave every build setting on its default —
   `vercel.json` overrides them. Do not set a Framework Preset, Root Directory,
   Build Command, or Output Directory in the dashboard.
4. Deploy. The first build takes about a minute.
5. Vercel serves the landing page at `https://<project>.vercel.app/`.

Project settings are only defaults. `vercel.json` wins for every key it sets, so
the import needs no manual configuration.

## Verify a deploy

```sh
# The page itself
curl -sS -o /dev/null -w '%{http_code}\n' https://<project>.vercel.app/

# The manifest pulled in by the build step
curl -sS https://<project>.vercel.app/manifest.json | head -c 200

# Security headers from vercel.json
curl -sSI https://<project>.vercel.app/ | grep -iE 'x-content-type|x-frame|referrer|permissions'
```

Expected: `200` for the page, a JSON body containing a `version` field, and the
four header lines. If `manifest.json` returns 404, the build step could not reach
GitHub Releases — the page still works, because `app.js` then falls back to the
GitHub API. The build log prints the reason.

## How the site stays correct on any domain

Three things were moved off the old `vidokun.github.io/Maccar/` absolute URLs so
the page works on the preview URL, the production URL, and a custom domain alike:

- `docs/index.html` — canonical, `og:url`, `og:image`, `twitter:image`, and the
  JSON-LD `url`/`image`/`screenshot`/`@id` values are root-relative (`/`, `/assets/...`).
- `docs/app.js` — rewrites the canonical link to
  `window.location.origin + window.location.pathname` at runtime, so a custom
  domain produces a self-referencing canonical without a code change.
- `docs/robots.txt` — carries no `Sitemap:` line, because a sitemap needs an
  absolute URL that does not exist until the domain does.

`v1.0.0`-era URLs of the form `/Maccar/...` are 301-redirected to the equivalent
root path by the `redirects` block in `vercel.json`.

## Optional: add a sitemap after the first deploy

A sitemap requires absolute URLs. `sitemap.xml.example` in the repository root is
the template; it is deliberately not deployed.

1. Copy `sitemap.xml.example` to `docs/sitemap.xml`.
2. Replace every `YOUR-DOMAIN` with the real domain.
3. Append to `docs/robots.txt`:

   ```
   Sitemap: https://YOUR-DOMAIN/sitemap.xml
   ```

4. Bump the `?v=` strings on the `styles.css` and `app.js` tags in
   `docs/index.html`, then commit and push.

## Cache busting

`docs/index.html` loads `styles.css?v=<date>` and `app.js?v=<date>`. **Bump both
strings on every CSS or JS change.** Editing a stylesheet without changing the
query string leaves returning visitors on the cached copy — this has already
caused a shipped fix to look absent. The `Cache-Control` header on those two
files is one hour with `must-revalidate`, so a stale copy cannot outlive the URL.

Assets under `docs/assets/` are served `immutable` for a year, so an image
replacement needs a new filename, not just new bytes.

## Before importing: preflight checklist

Run these from the repository root. All must pass.

```sh
# 1. vercel.json is valid JSON
python3 -I -c "import json; json.load(open('vercel.json')); print('vercel.json OK')"

# 2. The site folder is what vercel.json publishes
python3 -I -c "import json; d=json.load(open('vercel.json')); assert d['outputDirectory']=='docs'; print('outputDirectory OK')"

# 3. No stale GitHub Pages URLs leak into the published site
test -z "$(grep -rl 'vidokun.github.io' docs/ || true)" && echo "no stale URLs"

# 4. No Node dependency is needed before the build runs
test ! -e package.json && echo "no package.json (no install step)"

# 5. The build script runs and exits 0
node scripts/prepare-vercel-site.mjs && echo "build step OK"

# 6. No tracked Pages workflow survives
test -z "$(ls .github/workflows/pages.yml 2>/dev/null)" && echo "GitHub Pages workflow removed"
```

Also confirm in the GitHub repository settings that Pages is disabled
(*Settings → Pages → Source: None*), so nothing competes with Vercel.

## What changed to make this possible

- `.github/workflows/pages.yml` — removed. Vercel is now the only publisher.
- `.github/workflows/release.yml` — the `deploy-pages` job and the `pages` /
  `id-token` permissions are gone; tags release the app without touching the site.
- `scripts/prepare-vercel-site.mjs` — new. Mirrors the released
  `manifest.json` into `docs/` at build time, exactly as the Pages workflow did.
  It exits 0 even when GitHub is unreachable, because the page has an API fallback.
- `.gitignore` — `docs/manifest.json` is ignored, so a committed copy can never
  advertise an outdated version.
- `docs/sitemap.xml` — removed while it pointed at GitHub Pages;
  `sitemap.xml.example` in the root replaces it until a real domain exists.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| 404 at the deployment URL | `outputDirectory` not applied | Confirm `vercel.json` is at the repository root and committed |
| Swift sources downloadable | `outputDirectory` missing | Same fix: it must be `docs` |
| Landing page shows an old version | Asset `?v=` not bumped | Bump both strings in `docs/index.html` |
| `manifest.json` 404 | Release unreachable at build time | Expected; the page falls back to the GitHub API |
| Preview deploys are indexed by Google | Preview URLs are public | Set *Deployment Protection* or leave `robots.txt` denying non-production hosts |
| `/Maccar/` returns 404 | Old Pages path | Handled by the `redirects` block; verify it is in `vercel.json` |
