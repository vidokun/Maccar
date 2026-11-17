#!/usr/bin/env node
/**
 * Vercel build step: mirror the released manifest into the served folder.
 *
 * The landing page fetches ./manifest.json to show the current version. GitHub
 * Releases is the source of truth for that file, but Vercel only sees the
 * repository, so the manifest has to be pulled in at build time.
 *
 * Failure is not fatal by design: app.js falls back to the GitHub releases API
 * when the file is missing, so a GitHub outage must not break the deploy. The
 * script therefore always exits 0 — it only removes a stale copy so the page
 * cannot advertise an outdated version.
 */
import { writeFile, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const MANIFEST_URL =
  'https://github.com/vidokun/Maccar/releases/latest/download/manifest.json';
const TIMEOUT_MS = 20_000;

const siteRoot = join(dirname(fileURLToPath(import.meta.url)), '..', 'docs');
const destination = join(siteRoot, 'manifest.json');

async function fetchManifest() {
  const response = await fetch(MANIFEST_URL, {
    signal: AbortSignal.timeout(TIMEOUT_MS),
    redirect: 'follow',
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const body = await response.text();
  // Parse rather than pattern-match: a truncated or HTML error page must never
  // be written out as if it were a manifest.
  const parsed = JSON.parse(body);
  if (!parsed || typeof parsed.version !== 'string') {
    throw new Error('manifest is missing a version field');
  }
  return body;
}

try {
  const body = await fetchManifest();
  await writeFile(destination, body);
  console.log('manifest.json mirrored into docs/');
} catch (error) {
  await rm(destination, { force: true });
  console.warn(
    `manifest.json not mirrored (${error.message}); ` +
      'the landing page will use its GitHub API fallback.',
  );
}
