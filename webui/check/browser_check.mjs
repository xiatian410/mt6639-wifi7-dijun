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
  const blocked = new URLSearchParams(location.search).get('migration') === 'blocked';
  window.__commands = [];
  const status = (full) => [
    'schema=mt6639-radio-status-v1', `mode=${full ? 'full' : 'light'}`,
    'boot=11111111-1111-4111-8111-111111111111', 'busy=0', 'six_module=present',
    `unified_ready=${blocked ? 0 : 1}`, `unified_reason=${blocked ? 'unified_reboot_required' : 'none'}`,
    'six_version=v0.4.2-dijun.1', 'six_status_rc=0', `six_state=${state.six ? 'active' : 'restored'}`,
    `six_tx=${state.six ? 'present' : 'none'}`, `six_guardian=${state.six ? 'alive' : 'none'}`,
    'six_profile=os4-g284297', 'six_compat_error=none', 'six_boot_default=0', `six_ready=${state.six ? 1 : 0}`,
    'six_card=[事务运行] 适配：os4-g284297 | 内核：匹配 | 驱动：匹配 | 配置：临时配置 | 事务：运行 | 6GHz：60个已注册信道 | 连接：未连接 | 更新：12:34:56。信道注册不代表业务通过。',
    'hotspot_module=present', 'hotspot_version=v0.4.2-dijun.1',
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
    if (args[0] === 'status' && new URLSearchParams(location.search).get('fail') === 'status') {
      return { out: [], code: 127 };
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
    if (args[0] === 'stop' && new URLSearchParams(location.search).get('fail') === 'network') {
      state.hotspot = 'idle';
      return { out: ['phase=hotspot_stop', 'phase=six_restore',
        'REJECT recovery_network_not_ready',
        'result=failed step=six_restore reason=recovery_network_not_ready detail=none rc=90'], code: 90 };
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
  navigation: {
    query: '', scheme: 'light', ksu: true,
    steps: [['tab', '配置'], ['shot', 'settings'], ['tab', '诊断'], ['shot', 'diagnostics'],
      ['tab', '关于'], ['shot', 'about'], ['tab', '首页'], ['shot', 'home'], ['onlyReads']],
  },
  status_failure: {
    query: '?fail=status', scheme: 'dark', ksu: true,
    steps: [['tab', '诊断'], ['shot', 'diagnostics'], ['wheel', 900], ['wait', 500], ['shot', 'logs_entry'],
      ['tab', '关于'], ['shot', 'about'], ['onlyReads']],
  },
  operation_navigation: {
    query: '', scheme: 'light', ksu: true,
    steps: [['tap', 359, 409], ['tab', '配置'], ['shot', 'busy'], ['tap', 200, 180],
      ['wait', 4200], ['shot', 'active_settings'], ['neverSent', 'radio-name.sh'],
      ['sent', ' start 80'], ['tab', '首页'], ['tap', 359, 409], ['wait', 1800], ['sent', ' stop']],
  },
  // Interactions. Coordinates are CSS pixels in the 412x892 phone viewport.
  ksu_migration: {
    query: '?migration=blocked', scheme: 'light', ksu: true,
    steps: [['tap', 359, 409], ['wait', 700], ['shot', 'blocked'],
      ['neverSent', ' start '], ['neverSent', ' six-on'], ['neverSent', ' six-refresh']],
  },
  ksu_flow: {
    query: '', scheme: 'light', ksu: true,
    steps: [['tap', 359, 409], ['wait', 900], ['shot', 'running'], ['wait', 3200], ['shot', 'started'],
      ['sent', ' start 80'], ['tap', 359, 409], ['wait', 1800], ['shot', 'stopped'], ['sent', ' stop']],
  },
  ksu_network: {
    query: '?fail=network', scheme: 'light', ksu: true,
    steps: [['tap', 359, 409], ['wait', 4200], ['sent', ' start 80'],
      ['tap', 359, 409], ['wait', 1600], ['sent', ' stop'], ['shot', 'readiness_dialog']],
  },
  ksu_fail: {
    query: '?fail=start', scheme: 'dark', ksu: true,
    steps: [['tap', 359, 409], ['wait', 2600], ['shot', 'dialog'], ['sent', ' start 80']],
  },
  ksu_name: {
    query: '', scheme: 'light', ksu: true,
    steps: [
      ['tab', '配置'], ['tap', 200, 180], ['wait', 800], ['shot', 'name_dialog'],
      ['inputFocused'], ['fillInput', 'Lab 演示'], ['wait', 200],
      ['shot', 'name_valid'], ['saveInput'], ['wait', 1200],
      ['shot', 'name_saved'],
      ['sentMatch', '4c616220e6bc94e7a4ba'], ['sentMatch', 'radio-name.sh.* set'],
      ['neverSent', 'Lab 演示'],
    ],
  },
  ksu_name_active: {
    query: '', scheme: 'light', ksu: true,
    steps: [['tap', 359, 409], ['wait', 4200], ['sent', ' start 80'],
      ['tab', '配置'], ['tap', 200, 180], ['wait', 800], ['shot', 'disabled'], ['neverSent', 'radio-name.sh']],
  },
  ksu_key: {
    query: '', scheme: 'light', ksu: true,
    steps: [
      ['tab', '配置'], ['tap', 200, 350], ['wait', 900], ['shot', 'dialog'],
      ['inputFocused'], ['fillInput', 'WiFi!$;Q7'], ['wait', 200],
      ['saveInput'], ['wait', 1200], ['shot', 'saved'],
      ['sentMatch', '5769466921243b5137'],
      ['sentMatch', 'radio-key.sh.* set'],
      ['neverSent', 'WiFi!$;Q7'],
    ],
  },
  ksu_width: {
    query: '', scheme: 'light', ksu: true,
    steps: [
      ['tab', '配置'], ['tap', 200, 275], ['wait', 900], ['shot', 'popup'],
      ['tap', 250, 465], ['wait', 1200], ['shot', 'selected'],
      ['sent', ' set-width 160'],
    ],
  },
  scroll: {
    query: '?demo=sta5g', scheme: 'light',
    steps: [['tab', '诊断'], ['wheel', 900], ['wait', 900], ['shot', 'conditions'], ['wheel', 900], ['wait', 900], ['shot', 'bottom']],
  },
  touch_scroll: {
    query: '?demo=active', scheme: 'light',
    steps: [['tab', '诊断'], ['touchCycles', 6], ['shot', 'after']],
  },
  wide: { query: '?demo=active', scheme: 'light', viewport: { width: 1180, height: 820 } },
  compact: { query: '', scheme: 'light', ksu: true, viewport: { width: 360, height: 800 },
    steps: [['tab', '配置'], ['shot', 'settings'], ['tab', '关于'], ['shot', 'about'], ['onlyReads']] },
  compact_dark: { query: '', scheme: 'dark', ksu: true, viewport: { width: 393, height: 852 },
    steps: [['tab', '配置'], ['shot', 'settings'], ['tab', '诊断'], ['shot', 'diagnostics'], ['onlyReads']] },
  ime: { query: '', scheme: 'dark', ksu: true,
    steps: [['tab', '配置'], ['tap', 200, 180], ['inputFocused'], ['imeChecks'], ['shot', 'native_input'],
      ['fillInput', '中文热点'], ['saveInput'], ['wait', 1000], ['sentMatch', 'radio-name.sh.* set'],
      ['tap', 200, 350], ['inputFocused'], ['fillInput', 'short'], ['inputInvalid'],
      ['cancelInput'], ['inputClosed'], ['neverSent', 'radio-key.sh']] },
  navigation_motion: { query: '', scheme: 'dark', ksu: true,
    steps: [['navMotion'], ['onlyReads']] },
};

const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader', '--use-angle=swiftshader'] });
let failed = 0;
for (const name of wanted.length ? wanted : Object.keys(scenarios)) {
  const s = scenarios[name];
  if (!s) { console.error(`unknown scenario ${name}`); failed++; continue; }
  const context = await browser.newContext({
    viewport: s.viewport || { width: 412, height: 892 }, deviceScaleFactor: 2, colorScheme: s.scheme,
    hasTouch: true, isMobile: !s.viewport || s.viewport.width < 720,
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
    if (action === 'tab') {
      const index = ['首页', '配置', '诊断', '关于'].indexOf(a);
      const { width, height } = page.viewportSize();
      const bar = Math.min(width - 48, 360);
      await page.touchscreen.tap((width - bar) / 2 + bar * (index + 0.5) / 4, height - 50);
      await page.waitForTimeout(500);
    }
    else if (action === 'onlyReads') {
      if ((await sent()).some((c) => !/ status( full)?$/.test(c))) problems.push('navigation sent a write command');
    }
    else if (action === 'tap') await page.touchscreen.tap(a, b);
    else if (action === 'inputFocused') {
      if (!await page.locator('.mt-input').evaluate((e) => e === document.activeElement)) problems.push('native input did not receive focus');
    }
    else if (action === 'fillInput') await page.locator('.mt-input').fill(a);
    else if (action === 'saveInput') await page.getByRole('button', { name: '保存', exact: true }).click();
    else if (action === 'cancelInput') await page.getByRole('button', { name: '取消', exact: true }).click();
    else if (action === 'inputClosed') {
      const restored = await page.evaluate(() => !document.querySelector('.mt-veil') &&
        !document.getElementById('composeApp').inert && !document.getElementById('composeApp').style.height);
      if (!restored) problems.push('input close did not restore Canvas');
    }
    else if (action === 'navMotion') {
      const { width, height } = page.viewportSize();
      const bar = Math.min(width - 48, 360);
      const clip = { x: 0, y: height - 120, width, height: 120 };
      const before = await page.screenshot({ clip });
      await page.touchscreen.tap((width - bar) / 2 + bar * 3.5 / 4, height - 50);
      await page.waitForTimeout(60);
      const during = await page.screenshot({ clip, path: join(outDir, `${name}_during.png`) });
      await page.waitForTimeout(400);
      const after = await page.screenshot({ clip, path: join(outDir, `${name}_after.png`) });
      if (before.equals(during) || during.equals(after)) problems.push('navigation had no distinct intermediate frame');
    }
    else if (action === 'inputInvalid') {
      if (!await page.getByRole('button', { name: '保存', exact: true }).isDisabled()) problems.push('invalid input enabled save');
    }
    else if (action === 'imeChecks') {
      const original = page.viewportSize();
      const canvasHeight = await page.locator('#composeApp').evaluate((e) => e.getBoundingClientRect().height);
      await page.locator('.mt-input').fill('中');
      await page.locator('.mt-input').dispatchEvent('compositionstart');
      await page.locator('.mt-input').press('Enter');
      if ((await sent()).some((c) => c.includes('radio-name.sh'))) problems.push('IME composition submitted prematurely');
      await page.locator('.mt-input').dispatchEvent('compositionend');
      // Emulate IME resize increments. This checks layout/focus stability, not
      // whether a physical Android keyboard actually opens.
      for (const height of [760, 640, 520, 440]) {
        await page.setViewportSize({ width: original.width, height });
        await page.waitForTimeout(60);
        const geometry = await page.evaluate(() => {
          const input = document.querySelector('.mt-input');
          const r = input.getBoundingClientRect();
          return { top: r.top, bottom: r.bottom, focused: input === document.activeElement,
            canvas: document.getElementById('composeApp').getBoundingClientRect().height,
            vh: visualViewport.height, offset: visualViewport.offsetTop };
        });
        if (!geometry.focused || geometry.canvas !== canvasHeight || geometry.top < geometry.offset || geometry.bottom > geometry.vh + geometry.offset)
          problems.push(`IME resize ${height}: input or Canvas moved out of bounds`);
      }
      await page.screenshot({ path: join(outDir, `${name}_keyboard_resize.png`) });
      const before = await page.locator('.mt-card').evaluate((e) => getComputedStyle(e).backgroundColor);
      await page.emulateMedia({ colorScheme: 'light' });
      await page.waitForTimeout(300);
      const after = await page.locator('.mt-card').evaluate((e) => getComputedStyle(e).backgroundColor);
      if (before === after) problems.push('open input did not follow theme change');
      await page.setViewportSize(original);
      await page.waitForTimeout(150);
    }
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
