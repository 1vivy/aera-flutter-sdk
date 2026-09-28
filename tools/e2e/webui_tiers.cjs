// Loads a surfaces app in Chromium under each fake WebUI host tier (via
// `surfaces serve`), with a phone-sized viewport, and records what happened:
// a screenshot per step, console errors, and the host report the app
// exposes through Flutter's semantics tree.
//
//   NODE_PATH=$(npm root -g) node tools/e2e/webui_tiers.cjs <app-dir> <out-dir> [tier...] [--script steps.cjs]
//
// A steps file exports `async (page, h) => {...}` and drives the app with
// the helpers in `h` (tap by label, wait for text, Back, shots).

const { chromium } = require('playwright');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const scriptIndex = args.indexOf('--script');
const script = scriptIndex >= 0 ? require(path.resolve(args.splice(scriptIndex, 2)[1])) : null;
const [appDir, outDir, ...tierArgs] = args;
const tiers = tierArgs.length ? tierArgs : ['webuix', 'kernelsu', 'next', 'apatch', 'standalone', 'browser'];
fs.mkdirSync(outDir, { recursive: true });

function serve(tier, port) {
  return new Promise((resolve, reject) => {
    const child = spawn('dart', ['run', 'surfaces_cli:surfaces', 'serve', '--host', tier, '--port', String(port),
      '--no-build', '--no-panel'], { cwd: appDir, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
    let log = '';
    const onData = (d) => {
      log += d;
      if (/Serving /.test(log)) resolve(child);
    };
    child.stdout.on('data', onData);
    child.stderr.on('data', onData);
    child.on('exit', (code) => reject(new Error(`serve exited ${code}\n${log}`)));
    setTimeout(() => reject(new Error('serve did not start\n' + log)), 180000);
  });
}

async function run() {
  const browser = await chromium.launch({ args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader'] });
  const summary = {};
  let port = 8700;
  for (const tier of tiers) {
    port++;
    const server = await serve(tier, port);
    const context = await browser.newContext({
      viewport: { width: 400, height: 860 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, locale: 'en-US',
      userAgent: 'Mozilla/5.0 (Linux; Android 16; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36',
    });
    const page = await context.newPage();
    const errors = [];
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    page.on('pageerror', (e) => errors.push(String(e)));
    const started = Date.now();
    await page.goto(`http://127.0.0.1:${port}/?semantics=1`);
    await page.waitForFunction(() => !document.getElementById('splash'), null, { timeout: 120000 });
    const firstFrameMs = Date.now() - started;
    await page.waitForTimeout(1500);
    let n = 0;
    const h = {
      tier,
      shot: async (name) => page.screenshot({ path: path.join(outDir, `${tier}-${String(++n).padStart(2, '0')}-${name}.png`) }),
      // Text as Flutter's semantics tree exposes it; selectable text and
      // text fields are <textarea>/<input> elements with a label and value.
      text: async () => page.evaluate(() => Array.from(document.querySelectorAll('flt-semantics, flt-semantics-host textarea, flt-semantics-host input'))
        .map((e) => [e.getAttribute('aria-label') || (e.tagName.startsWith('FLT') ? e.textContent : ''), e.value || '']
          .join(' ').trim()).filter(Boolean).join(' | ')),
      tap: async (label) => {
        const loc = page.locator(`flt-semantics[aria-label*="${label}"], flt-semantics:text-is("${label}"), [role=button]:has-text("${label}")`).first();
        await loc.waitFor({ timeout: 20000 });
        await loc.click();
        await page.waitForTimeout(600);
      },
      waitText: async (needle, timeout = 30000) => {
        const t0 = Date.now();
        while (Date.now() - t0 < timeout) {
          const t = await h.text();
          if (t.includes(needle)) return t;
          await page.waitForTimeout(300);
        }
        throw new Error(`"${needle}" never appeared on ${tier}; saw: ${(await h.text()).slice(0, 800)}`);
      },
      back: async () => { await page.evaluate(() => window.__surfacesHost ? window.__surfacesHost.back() : history.back()); await page.waitForTimeout(800); },
      closed: async () => page.evaluate(() => !!document.getElementById('__surfaces_closed')),
      hostEvents: async () => page.evaluate(() => (window.__surfacesHost ? window.__surfacesHost.events : [])),
    };
    const result = { firstFrameMs, errors };
    try {
      await h.shot('start');
      if (script) result.steps = await script(page, h);
      result.ok = true;
    } catch (e) {
      result.ok = false;
      result.failure = String(e.stack || e);
      await h.shot('failure');
    }
    result.hostEvents = await h.hostEvents();
    summary[tier] = result;
    await context.close();
    try { process.kill(-server.pid, 'SIGKILL'); } catch (e) {}
    await new Promise((r) => setTimeout(r, 500));
    console.log(`${tier}: ${result.ok ? 'ok' : 'FAILED'} (first frame ${firstFrameMs} ms, ${errors.length} console errors)`);
    if (!result.ok) console.log(result.failure);
  }
  fs.writeFileSync(path.join(outDir, 'summary.json'), JSON.stringify(summary, null, 2));
  await browser.close();
  const failed = Object.values(summary).filter((r) => !r.ok).length;
  process.exit(failed ? 1 : 0);
}

run().catch((e) => { console.error(e); process.exit(2); });
