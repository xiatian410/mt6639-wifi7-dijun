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

  // A plain input element for the passphrase, for WebViews in which the
  // canvas text field cannot raise the keyboard. The value goes only to onOk.
  function promptSecret(title, hint, onOk, onCancel) {
    var veil = element('div', 'mt-veil');
    var card = element('div', 'mt-card');
    var input = element('input', 'mt-input');
    var reveal = element('label', 'mt-reveal');
    var box = element('input');
    var row = element('div', 'mt-row');
    var cancel = element('button', 'mt-button', '取消');
    var ok = element('button', 'mt-button mt-primary', '确定');
    input.type = 'password';
    input.autocomplete = 'off';
    input.spellcheck = false;
    input.maxLength = 63;
    input.setAttribute('autocapitalize', 'off');
    input.setAttribute('autocorrect', 'off');
    box.type = 'checkbox';
    box.onchange = function () { input.type = box.checked ? 'text' : 'password'; };
    reveal.appendChild(box);
    reveal.appendChild(document.createTextNode(' 显示密码'));
    function close() {
      input.value = '';
      if (veil.parentNode) veil.parentNode.removeChild(veil);
    }
    cancel.onclick = function () { close(); onCancel(); };
    ok.onclick = function () { var value = input.value; close(); onOk(value); };
    input.onkeydown = function (e) { if (e.key === 'Enter') ok.onclick(); };
    row.appendChild(cancel);
    row.appendChild(ok);
    card.appendChild(element('div', 'mt-title', title));
    card.appendChild(element('div', 'mt-hint', hint));
    card.appendChild(input);
    card.appendChild(reveal);
    card.appendChild(row);
    veil.appendChild(card);
    document.body.appendChild(veil);
    input.focus();
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
    promptSecret: promptSecret,
    visible: function () { return document.visibilityState !== 'hidden'; },
    ready: function () {
      ready = true;
      var loading = document.getElementById('loading');
      if (loading && loading.parentNode) loading.parentNode.removeChild(loading);
    }
  };
})();
