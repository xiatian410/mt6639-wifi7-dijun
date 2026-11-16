// Opens a built webroot in headless Chromium and saves screenshots.
//
//   node webui/check/browser_check.mjs WEBROOT OUT_DIR [scenario ...]
//
// Run it from a directory whose node_modules has the `playwright` package and
// a Chromium it can launch. This is a maintainer aid for looking at the page
// on a desktop; it is not part of the module and says nothing about a phone's
// WebView.
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { extname, join, normalize, resolve } from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(join(process.cwd(), 'noop.js'));
const { chromium } = require('playwright');

const [webroot, outDir, ...wanted] = process.argv.slice(2);
if (!webroot || !outDir) {
  console.error('usage: browser_check.mjs WEBROOT OUT_DIR [scenario ...]');
  process.exit(64);
}
const root = resolve(webroot);
const types = {
  '.html': 'text/html; charset=utf-8', '.js': 'application/javascript', '.mjs': 'application/javascript',
  '.wasm': 'application/wasm', '.otf': 'font/otf', '.txt': 'text/plain; charset=utf-8',
};
const server = createServer(async (req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname));
  const file = join(root, path === '/' ? 'index.html' : path);
  if (!file.startsWith(root)) { res.writeHead(403).end(); return; }
  try {
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream' }).end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((done) => server.listen(0, '127.0.0.1', done));
const base = `http://127.0.0.1:${server.address().port}/`;
await mkdir(outDir, { recursive: true });

// A stand-in for the manager's `ksu` object that answers like the scripts do,
// delivered the way KernelSU delivers it: as separate script evaluations.
const ksuMock = () => {
  const state = { hotspot: 'idle', width: 20, pref: 80, key: true, six: true, ssidHex: '' };
  const failStart = new URLSearchParams(location.search).get('fail') === 'start';
  window.__commands = [];
  const status = (full) => [
    'schema=mt6639-radio-status-v1', `mode=${full ? 'full' : 'light'}`,
    'boot=11111111-1111-4111-8111-111111111111', 'busy=0', 'six_module=present',
    'six_version=v0.3.3-dijun.1', 'six_status_rc=0', `six_state=${state.six ? 'active' : 'restored'}`,
    `six_tx=${state.six ? 'present' : 'none'}`, `six_guardian=${state.six ? 'alive' : 'none'}`,
    'six_profile=os4-g284297', 'six_compat_error=none', 'six_boot_default=1', `six_ready=${state.six ? 1 : 0}`,
    'six_card=[事务运行] 适配：os4-g284297 | 内核：匹配 | 驱动：匹配 | 配置：临时配置 | 事务：运行 | 6GHz：60个已注册信道 | 连接：未连接 | 更新：12:34:56。信道注册不代表业务通过。',
    'hotspot_module=present', 'hotspot_version=v0.3.1-dijun.1',
    ...(full ? ['hotspot_status_rc=0', `hotspot_state=${state.hotspot}`,
      `hotspot_freq=${state.hotspot === 'active' ? 6135 : 'none'}`,
      `hotspot_channel=${state.hotspot === 'active' ? 37 : 'none'}`] : [`hotspot_state=${state.hotspot}`]),
    `hotspot_checked=${full ? 1 : 0}`, 'hotspot_snapshot=1',
    `hotspot_band=${state.hotspot === 'idle' ? 'none' : '6g'}`,
    `hotspot_width=${state.hotspot === 'idle' ? 'none' : state.width}`, 'hotspot_age=0',
    'enforcing=1', `ap_key=${state.key ? 1 : 0}`, 'ssid_status_rc=0', `ssid_hex=${state.ssidHex}`,
    ...(full ? ['integrity=1', 'identity=1', 'identity_reason=none'] : []),
    'wifi=1', 'sta=disconnected', 'sta_freq=none', 'upstream=cell', 'upstream_ok=1',
    'upstream_reason=none', 'cell_data=1', 'session_owns_6g=0', `pref_width=${state.pref}`, 'end=1',
  ];
  const answer = (command) => {
    const args = command.split('mt6639-hotspot ').pop().split(' ');
    if (command.includes('radio-key.sh')) { state.key = true; return { out: ['ap_key=1'], code: 0 }; }
    if (command.includes('radio-name.sh')) {
      const hex = command.split(' ')[1];
      if (hex) state.ssidHex = hex;
      return { out: [`ssid_hex=${state.ssidHex}`], code: 0 };
    }
    if (args[0] === 'status') return { out: status(args[1] === 'full'), code: 0 };
    if (args[0] === 'start' && failStart) {
      return {
        out: ['phase=preflight', 'phase=hotspot_start',
          'REJECT runner_exited_during_start reason=sta_band_incompatible_with_6g sta_freq=5180',
          'result=failed step=hotspot_start reason=runner_exited_during_start detail=sta_band_incompatible_with_6g rc=71'],
        code: 71, slow: 300,
      };
    }
    if (args[0] === 'start') {
      state.hotspot = 'active'; state.width = Number(args[1]);
      return { out: ['phase=preflight', 'phase=hotspot_start', 'phase=verify', 'result=ok'], code: 0, slow: 600 };
    }
    if (args[0] === 'stop') { state.hotspot = 'idle'; return { out: ['phase=hotspot_stop', 'result=ok'], code: 0, slow: 400 }; }
    if (args[0] === 'set-width') { state.pref = Number(args[1]); return { out: ['result=ok'], code: 0 }; }
    if (args[0] === 'six-off') {
      return { out: ['phase=six_restore', 'result=failed step=six_restore reason=hotspot_active detail=state=active rc=73'],
        err: ['REJECT hotspot_active'], code: 73 };
    }
    return { out: ['=== radio ===', '2026-11-16 12:00:00 op=start arg=80 begin'], code: 0 };
  };
  const post = (source, delay) => setTimeout(() => (0, eval)(source), delay);
  window.ksu = {
    exec() { throw new Error('the page must use spawn, which does not block'); },
    spawn(command, args, options, name) {
      window.__commands.push(command);
      if (args !== '[]' || options !== '{}') throw new Error('unexpected spawn arguments');
      const r = answer(command);
      let at = r.slow || 20;
      for (const line of r.out) {
        post(`(function(){try{${name}.stdout.emit('data', ${JSON.stringify(line)});}catch(e){console.error('emitData', e);}})();`, at);
        at += r.slow ? r.slow : 1;
      }
      for (const line of r.err || []) {
        post(`(function(){try{${name}.stderr.emit('data', ${JSON.stringify(line)});}catch(e){console.error('emitData', e);}})();`, at++);
      }
      post(`(function(){try{${name}.emit('exit', ${r.code});}catch(e){console.error('emitExit', e);}})();`, at + 5);
      if (r.code !== 0) {
        post(`(function(){try{var err=new Error();err.exitCode=${r.code};${name}.emit('error', err);}catch(e){console.error('emitErr', e);}})();`, at + 10);
      }
    },
  };
};

const scenarios = {
  fresh: { query: '', scheme: 'light' },
  ready: { query: '?demo=ready', scheme: 'light' },
  active: { query: '?demo=active', scheme: 'light' },
  active_dark: { query: '?demo=active', scheme: 'dark' },
  sta5g: { query: '?demo=sta5g', scheme: 'light' },
  nosix: { query: '?demo=nosix', scheme: 'dark' },
  missing: { query: '?demo=missing', scheme: 'light' },
  ksu: { query: '', scheme: 'light', ksu: true },
  // Interactions. Coordinates are CSS pixels in the 412x892 phone viewport.
  ksu_flow: {
    query: '', scheme: 'light', ksu: true,
    steps: [['tap', 359, 141], ['wait', 900], ['shot', 'running'], ['wait', 3200], ['shot', 'started'],
      ['sent', ' start 80'], ['tap', 359, 141], ['wait', 1800], ['shot', 'stopped'], ['sent', ' stop']],
  },
  ksu_fail: {
    query: '?fail=start', scheme: 'dark', ksu: true,
    steps: [['tap', 359, 141], ['wait', 2600], ['shot', 'dialog'], ['sent', ' start 80']],
  },
  ksu_name: {
    query: '', scheme: 'light', ksu: true,
    steps: [
      ['tap', 200, 304], ['wait', 800], ['shot', 'name_dialog'],
      ['tap', 200, 740], ['press', 'ControlOrMeta+A'], ['insert', 'Lab 演示'], ['wait', 200],
      ['shot', 'name_valid'], ['tap', 296, 830], ['wait', 1200],
      ['shot', 'name_saved'],
        ['sentMatch', '4c616220e6bc94e7a4ba'], ['sentMatch', 'radio-name.sh.* set'],
      ['sentMatch', 'radio-name.sh.* set'],
      ['neverSent', 'Lab 演示'],
    ],
  },
  ksu_name_active: {
    query: '', scheme: 'light', ksu: true,
    steps: [['tap', 359, 141], ['wait', 4200], ['sent', ' start 80'],
      ['tap', 200, 304], ['wait', 800], ['shot', 'disabled'], ['neverSent', 'radio-name.sh']],
  },
  ksu_key: {
    query: '', scheme: 'light', ksu: true,
    steps: [
      ['tap', 200, 420], ['wait', 900], ['shot', 'dialog'],
      ['tap', 200, 697], ['type', 'WiFi!$;Q7'], ['wait', 200],
      ['tap', 296, 796], ['wait', 1200], ['shot', 'saved'],
      ['sentMatch', '5769466921243b5137'],
      ['sentMatch', 'radio-key.sh.* set'],
      ['neverSent', 'WiFi!$;Q7'],
    ],
  },
  ksu_width: {
    query: '', scheme: 'light', ksu: true,
    steps: [
      ['tap', 200, 344], ['wait', 900], ['shot', 'popup'],
      ['tap', 250, 535], ['wait', 1200], ['shot', 'selected'],
      ['sent', ' set-width 160'],
    ],
  },
  scroll: {
    query: '?demo=sta5g', scheme: 'light',
    steps: [['wheel', 900], ['wait', 900], ['shot', 'conditions'], ['wheel', 900], ['wait', 900], ['shot', 'bottom']],
  },
  touch_scroll: {
    query: '?demo=active', scheme: 'light',
    steps: [['touchCycles', 6], ['shot', 'after']],
  },
  wide: { query: '?demo=active', scheme: 'light', viewport: { width: 1180, height: 820 } },
};

const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader', '--use-angle=swiftshader'] });
let failed = 0;
for (const name of wanted.length ? wanted : Object.keys(scenarios)) {
  const s = scenarios[name];
  if (!s) { console.error(`unknown scenario ${name}`); failed++; continue; }
  const context = await browser.newContext({
    viewport: s.viewport || { width: 412, height: 892 }, deviceScaleFactor: 2, colorScheme: s.scheme,
    hasTouch: !s.viewport, isMobile: !s.viewport,
  });
  const page = await context.newPage();
  const problems = [];
  page.on('pageerror', (e) => problems.push(`pageerror: ${e.message}`));
  page.on('console', (m) => { if (m.type() === 'error') problems.push(`console: ${m.text()}`); });
  page.on('requestfailed', (r) => problems.push(`requestfailed: ${r.url()}`));
  page.on('response', (r) => { if (r.status() >= 400) problems.push(`http ${r.status()}: ${r.url()}`); });
  if (s.ksu) await page.addInitScript(ksuMock);
  const started = Date.now();
  await page.goto(base + s.query);
  try {
    await page.waitForFunction(() => !document.getElementById('loading'), null, { timeout: 90000 });
  } catch {
    problems.push('the loading overlay never went away');
  }
  const loadMs = Date.now() - started;
  await page.waitForTimeout(1500);
  await page.screenshot({ path: join(outDir, `${name}.png`) });
  let commands = [];
  const sent = async () => (s.ksu ? page.evaluate(() => window.__commands) : []);
  for (const [action, a, b] of s.steps || []) {
    if (action === 'tap') await page.touchscreen.tap(a, b);
    else if (action === 'wait') await page.waitForTimeout(a);
    else if (action === 'shot') await page.screenshot({ path: join(outDir, `${name}_${a}.png`) });
    else if (action === 'touchCycles') {
      const cdp = await context.newCDPSession(page);
      await page.evaluate(() => {
        window.__touchCancels = 0;
        document.addEventListener('pointercancel', () => window.__touchCancels++);
      });
      const swipe = async (from, to) => {
        await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: 206, y: from }] });
        for (let i = 1; i <= 16; i++) {
          await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: 206, y: from + (to - from) * i / 16 }] });
          await page.waitForTimeout(20);
        }
        await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
        await page.waitForTimeout(750);
      };
      for (let i = 0; i < a; i++) {
        const before = await page.screenshot();
        await swipe(740, 250);
        const down = await page.screenshot();
        if (before.equals(down)) problems.push(`touch cycle ${i}: upward swipe did not move content`);
        await page.screenshot({ path: join(outDir, `${name}_down_${i}.png`) });
        await swipe(250, 740);
        const up = await page.screenshot();
        if (down.equals(up)) problems.push(`touch cycle ${i}: downward swipe did not move content`);
      }
      const cancels = await page.evaluate(() => window.__touchCancels);
      if (cancels) problems.push(`browser cancelled ${cancels} touch gesture(s)`);
      await cdp.detach();
    }
    else if (action === 'press') await page.keyboard.press(a);
    else if (action === 'insert') await page.keyboard.insertText(a);
    else if (action === 'type') await page.keyboard.type(a, { delay: 20 });
    else if (action === 'wheel') { await page.mouse.move(206, 600); await page.mouse.wheel(0, a); }
    else if (action === 'sent' && !(await sent()).some((c) => c.endsWith(a))) problems.push(`no command ending in "${a}"`);
    else if (action === 'sentMatch' && !(await sent()).some((c) => (a instanceof RegExp ? a : new RegExp(a)).test(c))) problems.push(`no command matching ${a}`);
    else if (action === 'neverSent' && (await sent()).some((c) => c.includes(a))) problems.push(`a command contained "${a}"`);
  }
  if (s.ksu) {
    commands = await sent();
    if (!commands.length || !commands[0].endsWith(' status full')) {
      problems.push('the first command was not a full status');
    }
  }
  console.log(`${name}: loaded in ${loadMs} ms, ${problems.length} problem(s)` +
    (commands.length ? `, commands: ${commands.map((c) => c.split('mt6639-hotspot ').pop()).join(' | ')}` : ''));
  for (const p of problems) console.log(`  ${p}`);
  failed += problems.length;
  await context.close();
}
await browser.close();
server.close();
process.exit(failed ? 1 : 0);
