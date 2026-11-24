#!/usr/bin/env node

// Load the staged examples/15_webgpu_feasibility page in headless Chromium,
// wait for the fixture's asynchronous readback matrix, and save the console
// log plus a screenshot. Chromium's WebGPU adapter availability depends on the
// host Vulkan setup, so try the configured profiles in order and report which
// one produced the matrix. This is feasibility evidence, not a GPU benchmark.

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

const url = process.env.WEBGPU_URL || 'http://127.0.0.1:8765/';
const outDir = path.resolve(process.env.OUT_DIR || 'out/webgpu-browser');
const lavapipeIcd = process.env.LAVAPIPE_ICD || '';
const profileTimeoutMs = Number(process.env.WEBGPU_PROFILE_TIMEOUT_MS || 150000);

const markers = [
  ['adapter', 'browser adapter classification'],
  ['readback-core', 'async RGBA8 readback core PASS'],
  ['readback-compositor', 'async RGBA8 readback compositor PASS'],
  ['readback-effects', 'async RGBA8 readback effects PASS'],
  ['readback-material', 'rounded accessibility-material readback PASS'],
  ['controlled-text-readback', 'controlled text field GPU readback PASS'],
];

function chromiumDir() {
  return path.dirname(chromium.executablePath());
}

function bundledSwiftshaderIcd() {
  const candidate = path.join(chromiumDir(), 'vk_swiftshader_icd.json');
  return fs.existsSync(candidate) ? candidate : '';
}

const commonArgs = [
  '--no-sandbox',
  '--disable-gpu-sandbox',
  '--disable-dev-shm-usage',
  '--ignore-gpu-blocklist',
  '--enable-unsafe-webgpu',
  '--enable-unsafe-swiftshader',
  '--enable-features=Vulkan',
  '--disable-vulkan-surface',
];

function profiles() {
  const list = [];
  if (lavapipeIcd) {
    list.push({
      name: 'lavapipe-vulkan',
      args: commonArgs,
      env: { VK_ICD_FILENAMES: lavapipeIcd },
    });
  }
  const swiftshader = bundledSwiftshaderIcd();
  list.push({
    name: 'chromium-swiftshader-vulkan',
    args: [...commonArgs, '--use-vulkan=swiftshader'],
    env: swiftshader ? { VK_ICD_FILENAMES: swiftshader } : {},
  });
  list.push({
    name: 'chromium-angle-swiftshader',
    args: [...commonArgs, '--use-angle=swiftshader', '--use-webgpu-adapter=swiftshader'],
    env: swiftshader ? { VK_ICD_FILENAMES: swiftshader } : {},
  });
  return list;
}

function timestamp() {
  return new Date().toISOString();
}

async function runProfile(profile) {
  const lines = [];
  const seen = new Map();
  const browser = await chromium.launch({
    headless: true,
    args: profile.args,
    env: { ...process.env, ...profile.env },
  });
  const started = Date.now();
  try {
    const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    page.on('console', (message) => {
      const line = `[${message.type()}] ${message.text()}`;
      lines.push(line);
      const text = message.text();
      for (const [name, marker] of markers) {
        if (!seen.has(name) && text.includes(marker)) seen.set(name, line);
      }
    });
    page.on('pageerror', (error) => {
      lines.push(`[pageerror] ${error.stack || error.message}`);
    });
    await page.goto(url, { waitUntil: 'load', timeout: 60000 });

    const deadline = Date.now() + profileTimeoutMs;
    while (Date.now() < deadline) {
      const missing = markers.filter(([name]) => !seen.has(name));
      if (missing.length === 0) break;
      const status = await page.textContent('#status').catch(() => '');
      if (/Browser runtime error|Browser async error|WebGPU fixture failed|device was lost/.test(status || '')) {
        lines.push(`[status] ${status}`);
        break;
      }
      await page.waitForTimeout(500);
    }

    const missing = markers.filter(([name]) => !seen.has(name));
    const status = await page.textContent('#status').catch(() => '');
    const elapsedMs = Date.now() - started;
    return {
      profile: profile.name,
      args: profile.args,
      env: profile.env,
      elapsedMs,
      status: status || '',
      missing: missing.map(([name]) => name),
      adapter: seen.get('adapter') || '',
      lines,
      page,
      browser,
    };
  } catch (error) {
    await browser.close().catch(() => {});
    throw error;
  }
}

async function main() {
  fs.mkdirSync(outDir, { recursive: true });
  const attempts = [];
  for (const profile of profiles()) {
    process.stdout.write(`[webgpu-browser] trying ${profile.name}\n`);
    let result;
    try {
      result = await runProfile(profile);
      attempts.push({ profile: profile.name, missing: result.missing, status: result.status, elapsedMs: result.elapsedMs });

      const logPath = path.join(outDir, `console-${profile.name}.txt`);
      fs.writeFileSync(
        logPath,
        [
          `# Chromium WebGPU feasibility capture (${timestamp()})`,
          `# URL: ${url}`,
          `# Profile: ${profile.name}`,
          `# Args: ${profile.args.join(' ')}`,
          `# Env: ${JSON.stringify(profile.env)}`,
          `# Status: ${result.status}`,
          `# Elapsed: ${result.elapsedMs} ms`,
          `# Missing markers: ${result.missing.length === 0 ? '(none)' : result.missing.join(', ')}`,
          '',
          ...result.lines,
          '',
        ].join('\n'),
      );

      if (result.missing.length === 0) {
        await result.page.screenshot({ path: path.join(outDir, `screenshot-${profile.name}.png`) });
        fs.writeFileSync(
          path.join(outDir, 'result.txt'),
          [
            `profile=${profile.name}`,
            `elapsed_ms=${result.elapsedMs}`,
            `status=${result.status.replace(/\s+/g, ' ').trim()}`,
            `adapter=${result.adapter}`,
            ...markers.map(([name]) => `${name}=${seenLine(result.lines, name)}`),
            '',
          ].join('\n'),
        );
        process.stdout.write(`${result.adapter}\n`);
        process.stdout.write(`[webgpu-browser] PASS via ${profile.name} in ${result.elapsedMs} ms\n`);
        await result.browser.close().catch(() => {});
        result = null;
        return 0;
      }
      process.stdout.write(
        `[webgpu-browser] ${profile.name} missing: ${result.missing.join(', ')}; status=${result.status}\n`,
      );
      await result.page.screenshot({ path: path.join(outDir, `failed-${profile.name}.png`) });
      await result.page.close().catch(() => {});
    } catch (error) {
      attempts.push({ profile: profile.name, error: String(error && error.message || error) });
      process.stdout.write(`[webgpu-browser] ${profile.name} failed: ${error}\n`);
    } finally {
      if (result && result.browser) await result.browser.close().catch(() => {});
    }
  }
  fs.writeFileSync(path.join(outDir, 'attempts.json'), JSON.stringify(attempts, null, 2) + '\n');
  process.stderr.write(`[webgpu-browser] no profile completed the readback matrix at ${url}\n`);
  return 1;
}

function seenLine(lines, name) {
  const marker = markers.find(([markerName]) => markerName === name)[1];
  return lines.find((line) => line.includes(marker)) || '(missing)';
}

main().then((code) => process.exit(code)).catch((error) => {
  process.stderr.write(`[webgpu-browser] fatal: ${error && error.stack || error}\n`);
  process.exit(2);
});
