// KernelSU WebUI bridge for the MT6639 console. Plain script, no build step.
//
// The manager injects a `ksu` object. `ksu.spawn(command, argsJson,
// optionsJson, name)` runs a root shell command without blocking the page and
// reports through `window[name]`: `.stdout.emit('data', line)`,
// `.stderr.emit('data', line)` and `.emit('exit', code)`. `ksu.exec` is the
// blocking form older managers have; it is used only when spawn is missing.
(function () {
  'use strict';

  var seq = 0;
  var ready = false;

  function ksuObject() {
    return typeof window.ksu === 'object' && window.ksu !== null ? window.ksu : null;
  }

  function each(text, isStderr, onLine) {
    if (text === undefined || text === null || text === '') return;
    var lines = String(text).split('\n');
    for (var i = 0; i < lines.length; i++) onLine(isStderr, lines[i]);
  }

  // run(command, onLine(isStderr, text), onDone(exitCode)). onDone is called
  // exactly once; -1 means the command could not be handed to the manager.
  function run(command, onLine, onDone) {
    var ksu = ksuObject();
    var name = 'mt6639_cb_' + Date.now() + '_' + seq++;
    var finished = false;

    function finish(code) {
      if (finished) return;
      finished = true;
      // The manager may still deliver an "error" event after "exit".
      setTimeout(function () {
        try { delete window[name]; } catch (e) { window[name] = undefined; }
      }, 5000);
      onDone(typeof code === 'number' && isFinite(code) ? code | 0 : -1);
    }

    if (!ksu) {
      finish(-1);
      return;
    }
    try {
      if (typeof ksu.spawn === 'function') {
        window[name] = {
          stdout: { emit: function (event, data) { if (event === 'data') each(data, false, onLine); } },
          stderr: { emit: function (event, data) { if (event === 'data') each(data, true, onLine); } },
          emit: function (event, value) { if (event === 'exit') finish(value); }
        };
        ksu.spawn(command, '[]', '{}', name);
      } else {
        window[name] = function (errno, stdout, stderr) {
          each(stdout, false, onLine);
          each(stderr, true, onLine);
          finish(errno);
        };
        ksu.exec(command, '{}', name);
      }
    } catch (e) {
      onLine(true, 'bridge: ' + e);
      finish(-1);
    }
  }

  // Bytes travel as base64 text; the page decodes them.
  function fetchBase64(url, onOk, onErr) {
    fetch(url, { credentials: 'omit' })
      .then(function (r) {
        if (!r.ok) throw new Error('http ' + r.status);
        return r.arrayBuffer();
      })
      .then(function (buffer) {
        var bytes = new Uint8Array(buffer);
        var parts = [];
        for (var i = 0; i < bytes.length; i += 0x8000) {
          parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)));
        }
        onOk(btoa(parts.join('')));
      })
      .catch(function (e) { onErr(String(e)); });
  }

  function element(tag, className, text) {
    var e = document.createElement(tag);
    if (className) e.className = className;
    if (text) e.textContent = text;
    return e;
  }

  var dismissInput = null;

  // The same resolved Miuix palette drives Canvas and DOM, including live theme changes.
  function setTheme(page, card, text, weak, line, primary, onPrimary, field, error) {
    var values = { page: page, card: card, text: text, weak: weak, line: line,
      primary: primary, 'on-primary': onPrimary, field: field, error: error };
    Object.keys(values).forEach(function (key) {
      document.documentElement.style.setProperty('--' + key, values[key]);
    });
  }

  // Called synchronously from the user's click: focus is not deferred through
  // a Compose effect/timer, so WebView sees a real editable element and gesture.
  function promptInput(title, hint, initial, secret, validate, save) {
    if (dismissInput) dismissInput();
    var veil = element('div', 'mt-veil');
    var card = element('form', 'mt-card');
    var input = element('input', 'mt-input');
    var row = element('div', 'mt-row');
    var cancel = element('button', 'mt-button', '取消');
    var ok = element('button', 'mt-button mt-primary', '保存');
    var message = element('div', 'mt-validation');
    var composing = false;
    var closed = false;
    var previousFocus = document.activeElement;
    var surface = document.getElementById('composeApp');
    var previousStyle = surface ? surface.getAttribute('style') : null;
    var previousInert = surface ? surface.inert : false;
    var viewport = window.visualViewport;
    var frame = 0;
    input.type = secret ? 'password' : 'text';
    input.value = initial;
    input.autocomplete = 'off';
    input.spellcheck = false;
    input.setAttribute('aria-label', title);
    input.setAttribute('aria-describedby', 'mt-input-error');
    input.setAttribute('enterkeyhint', 'done');
    input.setAttribute('autocapitalize', 'off');
    input.setAttribute('autocorrect', 'off');
    message.id = 'mt-input-error';
    message.setAttribute('aria-live', 'polite');
    card.setAttribute('role', 'dialog');
    card.setAttribute('aria-modal', 'true');
    card.setAttribute('aria-label', title);
    cancel.type = 'button';
    ok.type = 'submit';

    // Freeze only the covered Canvas during IME resize. The DOM sheet follows
    // the visual viewport once per frame, with no CSS height/position animation
    // and no scrollIntoView/focus loops competing with the keyboard animation.
    if (surface) {
      surface.style.width = surface.clientWidth + 'px';
      surface.style.height = surface.clientHeight + 'px';
      surface.style.right = 'auto'; surface.style.bottom = 'auto';
      surface.inert = true;
    }
    function layout() {
      frame = 0;
      var height = viewport ? viewport.height : window.innerHeight;
      var top = viewport ? viewport.offsetTop : 0;
      veil.style.height = height + 'px';
      veil.style.top = top + 'px';
    }
    function scheduleLayout() {
      if (!frame) frame = requestAnimationFrame(layout);
    }
    function check() {
      var problem = validate(input.value);
      message.textContent = problem;
      input.setAttribute('aria-invalid', problem ? 'true' : 'false');
      ok.disabled = composing || !!problem;
      return !problem && !composing;
    }
    function close() {
      if (closed) return;
      closed = true;
      input.value = '';
      input.blur();
      if (frame) cancelAnimationFrame(frame);
      window.removeEventListener('resize', scheduleLayout);
      if (viewport) { viewport.removeEventListener('resize', scheduleLayout); viewport.removeEventListener('scroll', scheduleLayout); }
      veil.remove();
      if (surface) {
        if (previousStyle === null) surface.removeAttribute('style'); else surface.setAttribute('style', previousStyle);
        surface.inert = previousInert;
      }
      dismissInput = null;
      if (previousFocus && previousFocus.isConnected && previousFocus !== document.body) previousFocus.focus({ preventScroll: true });
    }
    dismissInput = close;
    cancel.onclick = close;
    veil.onclick = function (e) { if (e.target === veil) close(); };
    card.onsubmit = function (e) {
      e.preventDefault();
      if (!check()) return;
      if (save(input.value)) close();
      else message.textContent = '当前状态不允许保存，请关闭后重试。';
    };
    input.oninput = check;
    input.addEventListener('compositionstart', function () { composing = true; ok.disabled = true; });
    input.addEventListener('compositionend', function () { composing = false; check(); });
    veil.onkeydown = function (e) {
      if (e.key === 'Escape') { e.preventDefault(); close(); }
      if (e.key === 'Enter' && (composing || e.isComposing)) e.preventDefault();
      if (e.key === 'Tab') {
        var controls = Array.from(card.querySelectorAll('input, button')).filter(function (el) { return !el.disabled; });
        var first = controls[0], last = controls[controls.length - 1];
        if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
        else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
      }
    };
    card.appendChild(element('div', 'mt-title', title));
    card.appendChild(element('div', 'mt-hint', hint));
    card.appendChild(input);
    card.appendChild(message);
    if (secret) {
      var reveal = element('label', 'mt-reveal');
      var box = element('input'); box.type = 'checkbox';
      box.onchange = function () { input.type = box.checked ? 'text' : 'password'; };
      reveal.appendChild(box); reveal.appendChild(document.createTextNode(' 显示密码'));
      card.appendChild(reveal);
    }
    row.appendChild(cancel); row.appendChild(ok); card.appendChild(row); veil.appendChild(card);
    document.body.appendChild(veil);
    window.addEventListener('resize', scheduleLayout);
    if (viewport) { viewport.addEventListener('resize', scheduleLayout); viewport.addEventListener('scroll', scheduleLayout); }
    layout(); check();
    input.focus({ preventScroll: true });
  }

  function fatal(message) {
    if (ready) return;
    var box = document.getElementById('fatal');
    var loading = document.getElementById('loading');
    if (!box) return;
    document.getElementById('fatal-detail').textContent = message;
    box.hidden = false;
    if (loading) loading.hidden = true;
  }

  window.addEventListener('error', function (e) {
    fatal(e && e.message ? e.message : '脚本加载失败');
  });
  window.addEventListener('unhandledrejection', function (e) {
    fatal(e && e.reason ? String(e.reason) : '加载被拒绝');
  });
  setTimeout(function () {
    if (!ready && document.getElementById('fatal').hidden) {
      var slow = document.getElementById('loading-text');
      if (slow) slow.textContent = '加载比预期久，请稍候…';
    }
  }, 20000);

  window.mt6639 = {
    available: function () { return ksuObject() !== null; },
    run: run,
    fetchBase64: fetchBase64,
    promptInput: promptInput,
    setTheme: setTheme,
    visible: function () { return document.visibilityState !== 'hidden'; },
    ready: function () {
      ready = true;
      var loading = document.getElementById('loading');
      if (loading && loading.parentNode) loading.parentNode.removeChild(loading);
    }
  };
})();
