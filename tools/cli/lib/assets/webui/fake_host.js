// A stand-in for a root manager's WebUI host, injected by `surfaces serve`.
// It gives the page the same globals, quirks and gaps as the chosen tier, so
// the app's per-feature fallbacks can be tried in any browser. Commands go
// to the dev server, which runs them on this PC (in a sandboxed fake device
// root) or on a phone with --adb.
//
// Faithful quirks: on every tier except WebUI X, ksu.exec runs inside the
// call (a synchronous request), so the page freezes until the command ends,
// exactly as KernelSU's @JavascriptInterface does. WebUI X runs it in the
// background and posts WX_* events.
(function () {
  'use strict';
  var cfg = window.__SURFACES_FAKE__;
  var tier = cfg.tier;
  var webuix = tier === 'webuix';

  function run(cmd, sync, done) {
    var body = JSON.stringify({ cmd: cmd });
    if (sync) {
      var xhr = new XMLHttpRequest();
      xhr.open('POST', '/__surfaces/exec', false);
      xhr.setRequestHeader('content-type', 'application/json');
      xhr.send(body);
      done(JSON.parse(xhr.responseText));
      return;
    }
    fetch('/__surfaces/exec', { method: 'POST', body: body, headers: { 'content-type': 'application/json' } })
      .then(function (r) { return r.json(); })
      .then(done, function (e) { done({ code: 1, stdout: '', stderr: String(e) }); });
  }

  function callback(name, args) {
    // Hosts call the named global later, through loadUrl("javascript:...").
    setTimeout(function () {
      var fn = window[name];
      if (typeof fn === 'function') fn.apply(window, args);
    }, 0);
  }

  function toast(message) {
    var el = document.createElement('div');
    el.textContent = message;
    el.setAttribute('data-fake-toast', '');
    el.style.cssText = 'position:fixed;left:50%;bottom:64px;transform:translateX(-50%);' +
      'background:#323232;color:#fff;padding:10px 18px;border-radius:20px;font:14px sans-serif;' +
      'z-index:2147483647;pointer-events:none;max-width:80%;text-align:center';
    document.body.appendChild(el);
    log('toast: ' + message);
    setTimeout(function () { el.remove(); }, 2500);
  }

  var events = [];
  function log(line) {
    events.push(line);
    var panel = document.getElementById('__surfaces_log');
    if (panel) panel.textContent = events.slice(-4).join('\n');
  }

  var moduleInfo = JSON.stringify({
    moduleDir: cfg.moduleDir, id: cfg.moduleId, name: cfg.moduleName, version: cfg.version,
    versionCode: 1, author: 'surfaces', description: 'dev server', enabled: true,
    update: false, remove: false, web: true, action: false
  });

  var packages = [
    { packageName: 'com.android.chrome', appLabel: 'Chrome', versionName: '130.0', versionCode: 1, isSystem: false, uid: 10100 },
    { packageName: 'com.termux', appLabel: 'Termux', versionName: '0.118', versionCode: 1, isSystem: false, uid: 10101 },
    { packageName: 'me.weishu.kernelsu', appLabel: 'KernelSU', versionName: '3.0', versionCode: 1, isSystem: false, uid: 10102 },
    { packageName: 'org.fdroid.fdroid', appLabel: 'F-Droid', versionName: '1.20', versionCode: 1, isSystem: false, uid: 10103 }
  ];

  var ksu = {
    exec: function (cmd, a, b) {
      var cb = b === undefined ? a : b;
      if (cb === undefined) {
        var out;
        run(cmd, true, function (r) { out = r.stdout; });
        return out;
      }
      log('exec' + (webuix ? '' : ' (blocking)') + ': ' + cmd.slice(0, 80));
      run(cmd, !webuix, function (r) { callback(cb, [r.code, r.stdout, r.stderr]); });
    },
    spawn: function (cmd, argsJson, opts, cb) {
      var line = cmd + ' ' + JSON.parse(argsJson || '[]').join(' ');
      run(line, false, function (r) {
        var child = window[cb];
        if (!child) return;
        if (webuix) { child.emit('exit', r.code); return; } // spawn output broken on v438
        r.stdout.split('\n').forEach(function (l) { if (l) child.stdout.emit('data', l); });
        r.stderr.split('\n').forEach(function (l) { if (l) child.stderr.emit('data', l); });
        child.emit('exit', r.code);
      });
    },
    toast: toast,
    fullScreen: function (on) { log('fullScreen(' + on + ')'); document.documentElement.setAttribute('data-fullscreen', on); },
    moduleInfo: function () { return moduleInfo; }
  };

  if (tier === 'kernelsu') {
    ksu.enableEdgeToEdge = function (on) { log('enableEdgeToEdge(' + on + ')'); };
    ksu.exit = function () { closed('ksu.exit()'); };
  }
  if (tier === 'next' || tier === 'apatch') {
    ksu.enableInsets = function (on) { log('enableInsets(' + on + ')'); };
  }
  if (tier === 'next') {
    ksu.listFile = function () { return '[]'; };
  }
  if (tier === 'apatch') {
    delete ksu.moduleInfo;
  }
  if (tier === 'kernelsu' || tier === 'next' || tier === 'apatch') {
    ksu.listPackages = function (type) { return JSON.stringify(packages.map(function (p) { return p.packageName; })); };
    ksu.getPackagesInfo = function (json) {
      var wanted = JSON.parse(json);
      return JSON.stringify(packages.filter(function (p) { return wanted.indexOf(p.packageName) >= 0; }));
    };
  }
  if (webuix) {
    ksu.mmrl = function () { return true; };
    ksu.execBool = function () { return true; };
    window.webui = {
      exit: function () { closed('webui.exit()'); },
      setRefreshing: function () {},
      getCurrentRootManager: function () { return { getPackageName: function () { return 'me.weishu.kernelsu'; } }; }
    };
    var mod = '$' + cfg.moduleId.replace(/[^A-Za-z0-9_]/g, '_');
    window[mod] = {
      isDarkMode: function () { return cfg.dark; },
      setLightStatusBars: function (light) { log('setLightStatusBars(' + light + ')'); },
      setLightNavigationBars: function () {},
      shareText: function (text) { log('shareText: ' + text); toast('Share sheet: ' + text.slice(0, 40)); },
      getSdk: function () { return 36; }
    };
    try {
      Object.defineProperty(navigator, 'userAgent', { get: function () { return cfg.userAgent + ' WebUI X/438'; } });
    } catch (e) {}
  }
  window.ksu = ksu;

  function post(type, data) {
    log('event: ' + type);
    window.postMessage(JSON.stringify({ type: type, data: data || {} }), '*');
  }

  function closed(how) {
    log(how);
    var el = document.createElement('div');
    el.id = '__surfaces_closed';
    el.textContent = 'The host closed the WebUI (' + how + ')';
    el.style.cssText = 'position:fixed;inset:0;background:#111;color:#eee;display:flex;align-items:center;' +
      'justify-content:center;font:18px sans-serif;z-index:2147483647';
    document.body.appendChild(el);
  }

  // What the host's Back does: WebUI X with backInterceptor "javascript"
  // posts WX_ON_BACK; the KernelSU family goes back in history while it can
  // and closes the WebUI when it cannot.
  function back() {
    if (webuix) { post('WX_ON_BACK'); return; }
    // WebView.canGoBack(): true unless we are on the first entry. Flutter
    // marks that one {origin: true} and the one above it {flutter: true}
    // (Navigator 1) or {serialCount: n} (Router).
    var st = history.state;
    if (st && (st.flutter || st.serialCount > 0)) { log('history.back()'); history.back(); return; }
    closed('Back with no history');
  }

  window.__surfacesHost = {
    tier: tier, back: back, events: events,
    pause: function () { post('WX_ON_PAUSE'); },
    resume: function () { post('WX_ON_RESUME'); },
    keyboard: function (visible) { post('WX_ON_KEYBOARD', { visible: visible, height: visible ? 800 : 0 }); }
  };

  function panel() {
    var box = document.createElement('div');
    box.style.cssText = 'position:fixed;right:8px;top:50%;transform:translateY(-50%);z-index:2147483646;' +
      'display:flex;flex-direction:column;gap:6px;font:12px sans-serif;align-items:flex-end';
    function button(label, fn) {
      var b = document.createElement('button');
      b.textContent = label;
      b.style.cssText = 'padding:6px 10px;border-radius:14px;border:0;background:#222c;color:#fff;cursor:pointer';
      b.onclick = fn;
      box.appendChild(b);
    }
    var badge = document.createElement('div');
    badge.textContent = 'fake host: ' + tier;
    badge.style.cssText = 'background:#b3261e;color:#fff;padding:4px 8px;border-radius:8px';
    box.appendChild(badge);
    button('◀ Back', back);
    if (webuix) {
      button('Pause', window.__surfacesHost.pause);
      button('Resume', window.__surfacesHost.resume);
    }
    var pre = document.createElement('pre');
    pre.id = '__surfaces_log';
    pre.style.cssText = 'margin:0;max-width:260px;white-space:pre-wrap;background:#000a;color:#9f9;padding:4px;border-radius:6px;font-size:10px';
    box.appendChild(pre);
    document.body.appendChild(box);
  }
  if (cfg.panel) {
    if (document.body) panel(); else document.addEventListener('DOMContentLoaded', panel);
  }
})();
