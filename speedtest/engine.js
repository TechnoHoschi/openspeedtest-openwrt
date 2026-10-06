/*
 * Messkern des LAN-Speedtests, gemeinsam fuer alle Design-Varianten.
 * Bewusst ES5 ohne Abhaengigkeiten, damit auch aeltere Browser (SmartTV) ihn ausfuehren.
 *
 * Antwortet die Router-API nicht (z. B. in einer Vorschau ausserhalb des Routers),
 * laeuft eine Demo mit simulierten Werten, damit das Design sichtbar bleibt.
 *
 *   SpeedEngine.init(function (info) { ... })       info.demo === true im Demo-Modus
 *   SpeedEngine.run({ streams, duration, label }, {
 *     phase(name),                 'ping' | 'download' | 'upload'
 *     pingSample(ms, i, count),
 *     ping(ms, jitter),
 *     live(kind, mbit, progress),  mbit === null in der ersten Sekunde
 *     result(kind, r),             r = { peak, avg, cpu, core, cores: [% je Kern], series: [mbit, ...] }
 *     done(record),                Datensatz, wie er im Verlauf landet
 *     error(message)
 *   })
 *   SpeedEngine.stop(); SpeedEngine.running()
 *   SpeedEngine.history(cb); SpeedEngine.clearHistory(cb)
 *   SpeedEngine.link(cb, demoPreset)  Verbindung des Geraets: { type: 'wired'|'wifi'|null, port, speed, duplex, wifi }
 *                                     demoPreset 'wifi' zeigt im Demo-Modus ein WLAN-Geraet
 *   SpeedEngine.fmtSpeed(mbit) -> { v: '1,42', u: 'Gbit/s' }
 */
(function () {
  'use strict';
  var API = '/speedtest-api';
  var PING_URL = '/speedtest/ping.txt';
  var UL_CHUNK = 32 * 1048576;     // gross, weil uhttpd in OpenWrt 25.12 jede Antwort ~40 ms verzoegert
  var XHR_DL_CHUNK = 32 * 1048576; // XHR-Fallback: nach so vielen Bytes neu anfragen, haelt den Browser-RAM klein
  var WARMUP = 1.5;                // Sekunden, die nicht in den Durchschnitt eingehen
  var PING_COUNT = 20;

  var info = null, demo = false, run = 0, active = false, demoHistory = [], demoWifi = false;

  function now() { return (window.performance && performance.now) ? performance.now() : Date.now(); }
  function fmt(n, d) { return n.toFixed(d).replace('.', ','); }
  function fmtSpeed(mbit) {
    if (mbit >= 1000) return { v: fmt(mbit / 1000, 2), u: 'Gbit/s' };
    return { v: fmt(mbit, mbit < 100 ? 1 : 0), u: 'Mbit/s' };
  }
  function bust(url) { return url + (url.indexOf('?') < 0 ? '?' : '&') + 'r=' + Math.random().toString(36).slice(2); }
  function round1(v) { return v === null || v === undefined ? null : Math.round(v * 10) / 10; }
  function clearRT() { if (window.performance && performance.clearResourceTimings) performance.clearResourceTimings(); }

  function req(method, url, body, cb) {
    var x = new XMLHttpRequest();
    x.open(method, bust(url));
    x.onload = function () {
      var d = null;
      try { d = JSON.parse(x.responseText); } catch (e) { }
      cb(x.status === 200 ? d : null);
    };
    x.onerror = function () { cb(null); };
    if (body) x.setRequestHeader('Content-Type', 'application/json');
    x.send(body || null);
  }

  // ---------- Router-CPU: zwei Schnappschuesse von /proc/stat ----------
  function CpuWatch() {
    var self = this, first = null;
    self.avg = null; self.core = null; self.cores = null;
    self.mark = function () {
      if (demo) return;
      req('GET', API + '/cpu', null, function (d) { if (d && d.length) first = d; });
    };
    self.finish = function (kind, cb) {
      if (demo) {
        self.avg = kind === 'download' ? 14 + Math.random() * 8 : 45 + Math.random() * 10;
        self.cores = [];
        for (var c = 0; c < info.cores; c++) self.cores.push(Math.min(100, self.avg * (c === 0 ? 1.6 : 0.5 + Math.random() * 0.8)));
        self.core = self.cores[0];
        return setTimeout(cb, 50);
      }
      req('GET', API + '/cpu', null, function (d) {
        if (d && first && d.length === first.length) {
          for (var i = 0; i < d.length; i++) {
            var dt = d[i][0] - first[i][0], di = d[i][1] - first[i][1];
            var busy = dt > 0 ? 100 * (dt - di) / dt : 0;
            if (i === 0) { self.avg = busy; self.cores = []; continue; }
            self.cores.push(busy);
            if (self.core === null || busy > self.core) self.core = busy;
          }
        }
        cb();
      });
    };
  }

  // ---------- Ping: Zeit bis zum ersten Antwort-Byte ----------
  // Die Gesamtzeit waere unbrauchbar: uhttpd in OpenWrt 25.12 haelt den Rest kleiner Antworten ~40 ms zurueck.
  function runPing(id, h, done) {
    var times = [], n = 0;
    var rt = !!(window.performance && performance.getEntriesByName);
    clearRT();
    function finish() {
      if (!times.length) return done(null, null);
      var sorted = times.slice().sort(function (a, b) { return a - b; });
      var med = sorted[Math.floor(sorted.length / 2)], j = 0;
      for (var i = 1; i < times.length; i++) j += Math.abs(times[i] - times[i - 1]);
      done(med, times.length > 1 ? j / (times.length - 1) : 0);
    }
    function sample(v) {
      if (n++ >= 2) { times.push(v); if (h.pingSample) h.pingSample(v, times.length - 1, PING_COUNT); }
      if (n < PING_COUNT + 2) one(); else finish();
    }
    function one() {
      if (id !== run) return;
      if (demo) return setTimeout(function () { if (id === run) sample(1.6 + Math.random() * 0.9); }, 60);
      var x = new XMLHttpRequest(), t0 = now(), url = bust(PING_URL);
      x.open('GET', url);
      x.onload = function () {
        if (id !== run) return;
        var v = now() - t0;
        if (rt) {
          var e = performance.getEntriesByName(location.protocol + '//' + location.host + url).pop();
          if (e && e.responseStart > 0 && e.requestStart > 0) v = e.responseStart - e.requestStart;
        }
        sample(v);
      };
      x.onerror = function () { if (id === run) finish(); };
      x.send();
    }
    one();
  }

  // ---------- Durchsatz ----------
  // Live-Anzeige und Spitze nutzen dieselben gleitenden 1-s-Werte.
  // Spitze = bester 1-s-Wert, Durchschnitt = 1-s-Werte nach dem Anlauf ohne die langsamsten 30 % und schnellsten 10 %.
  function runTransfer(id, kind, streams, duration, h, done) {
    var state = { stop: false, aborts: [] }, bytes = 0, t0 = now(), warm = null, samples = [], rates = [], series = [], peak = 0;
    var cpu = new CpuWatch(), demoTarget = demoWifi ? (kind === 'download' ? 880 : 610) : (kind === 'download' ? 2300 : 1450);
    function count(b) { bytes += b; }
    if (!demo) for (var i = 0; i < streams; i++) (kind === 'download' ? dlWorker : ulWorker)(state, count);
    function halt() {
      clearInterval(timer);
      state.stop = true;
      clearRT();
      for (var k = 0; k < state.aborts.length; k++) { try { state.aborts[k](); } catch (e) { } }
    }
    var timer = setInterval(function () {
      if (id !== run) return halt();
      var t = (now() - t0) / 1000;
      if (demo) {   // weiche Anlaufkurve mit etwas Rauschen
        var ramp = 1 - Math.exp(-t * 2.2);
        bytes += demoTarget * ramp * (0.9 + Math.random() * 0.14) * 1e6 / 8 * 0.2;
      }
      samples.push([t, bytes]);
      while (samples.length > 2 && t - samples[1][0] >= 1.0) samples.shift();
      var p = Math.min(1, t / duration);
      if (samples.length > 1 && t - samples[0][0] >= 0.95) {
        var rate = (bytes - samples[0][1]) * 8 / 1e6 / (t - samples[0][0]);
        if (rate > peak) peak = rate;
        if (warm !== null) rates.push(rate);
        series.push(rate);
        h.live(kind, rate, p);
      } else {
        h.live(kind, null, p);
      }
      if (warm === null && t >= WARMUP) { warm = [t, bytes]; cpu.mark(); }
      if (t >= duration) {
        halt();
        var avg = (warm && t > warm[0]) ? (bytes - warm[1]) * 8 / 1e6 / (t - warm[0]) : 0;
        if (rates.length >= 5) {
          rates.sort(function (a, b) { return a - b; });
          var keep = rates.slice(Math.floor(rates.length * 0.3), Math.ceil(rates.length * 0.9)), sum = 0;
          for (var j = 0; j < keep.length; j++) sum += keep[j];
          avg = sum / keep.length;
        }
        if (peak < avg) peak = avg;
        cpu.finish(kind, function () {
          if (id !== run) return;
          done({ peak: peak, avg: avg, cpu: cpu.avg, core: cpu.core, cores: cpu.cores, series: series });
        });
      }
    }, 200);
  }

  var canStream = !!(window.fetch && window.ReadableStream && window.AbortController &&
                     window.Response && 'body' in window.Response.prototype);

  function dlWorker(state, count) {
    var url = info.dl_url;
    function next() {
      if (state.stop) return;
      if (canStream) {
        var ctrl = new AbortController();
        state.aborts.push(function () { ctrl.abort(); });
        fetch(bust(url), { cache: 'no-store', signal: ctrl.signal }).then(function (res) {
          var reader = res.body.getReader();
          function pump() {
            return reader.read().then(function (r) {
              if (r.done) return next();
              count(r.value.length);
              if (state.stop) { ctrl.abort(); return; }
              return pump();
            });
          }
          return pump();
        })['catch'](function () { if (!state.stop) setTimeout(next, 200); });
      } else {
        var x = new XMLHttpRequest(), last = 0;
        state.aborts.push(function () { x.abort(); });
        x.open('GET', bust(url));
        x.onprogress = function (e) {
          count(e.loaded - last); last = e.loaded;
          if (state.stop || e.loaded >= XHR_DL_CHUNK) { x.onload = null; x.abort(); next(); }
        };
        x.onload = function (e) { count(e.loaded - last); next(); };
        x.onerror = function () { if (!state.stop) setTimeout(next, 200); };
        x.send();
      }
    }
    next();
  }

  var ulBlob = null;
  function ulWorker(state, count) {
    if (!ulBlob) ulBlob = new Blob([new Uint8Array(UL_CHUNK)]);
    function next() {
      if (state.stop) return;
      var x = new XMLHttpRequest(), last = 0;
      state.aborts.push(function () { x.abort(); });
      x.open('POST', bust(API + '/up'));
      x.upload.onprogress = function (e) { count(e.loaded - last); last = e.loaded; };
      x.onload = function () { count(UL_CHUNK - last); next(); };
      x.onerror = function () { if (!state.stop) setTimeout(next, 200); };
      x.send(ulBlob);
    }
    next();
  }

  // ---------- oeffentliche Schnittstelle ----------
  function init(cb) {
    req('GET', API + '/info', null, function (d) {
      if (d && d.dl_size) { info = d; demo = false; }
      else {
        demo = true;
        info = { demo: true, hostname: 'OpenWrt-BT8', model: 'ASUS ZenWiFi BT8 (Demo)', cores: 3,
                 soc: { vendor: 'MediaTek', chip: 'MT7988A', name: 'Filogic 880' },
                 client_ip: '192.168.1.3', client_host: 'yoga', dl_url: '', dl_size: 0 };
      }
      info.demo = demo;
      cb(info);
    });
  }

  function start(opts, h) {
    var id = ++run, streams = opts.streams || 4, duration = opts.duration || 10;
    var rec = { streams: streams, label: opts.label || '' };
    active = true;
    function fin() { active = false; }
    h.phase('ping');
    runPing(id, h, function (ping, jitter) {
      if (id !== run) return;
      if (ping === null) { fin(); return h.error('Der Router antwortet nicht.'); }
      rec.ping = round1(ping); rec.jitter = round1(jitter);
      h.ping(ping, jitter);
      h.phase('download');
      runTransfer(id, 'download', streams, duration, h, function (d) {
        rec.dl = round1(d.avg); rec.dl_peak = round1(d.peak); rec.cpu_dl = d.cpu === null ? null : Math.round(d.cpu); rec.core_dl = d.core === null ? null : Math.round(d.core);
        h.result('download', d);
        h.phase('upload');
        runTransfer(id, 'upload', streams, duration, h, function (u) {
          rec.ul = round1(u.avg); rec.ul_peak = round1(u.peak); rec.cpu_ul = u.cpu === null ? null : Math.round(u.cpu); rec.core_ul = u.core === null ? null : Math.round(u.core);
          h.result('upload', u);
          fin();
          save(rec, function (saved) { h.done(saved || rec); });
        });
      });
    });
  }

  function save(rec, cb) {
    if (demo) {
      var e = {}; for (var k in rec) e[k] = rec[k];
      e.ts = Math.floor(Date.now() / 1000); e.ip = info.client_ip; e.host = info.client_host;
      demoHistory.push(e);
      return cb(e);
    }
    req('POST', API + '/history', JSON.stringify(rec), cb);
  }

  function seedDemoHistory() {
    var t = Math.floor(Date.now() / 1000);
    demoHistory = [
      { ts: t - 5400, ip: '192.168.1.3', host: 'yoga', label: 'Yoga LAN', ping: 2.0, jitter: 0.4, dl: 2300, dl_peak: 2390, ul: 1380, ul_peak: 1480, streams: 4, core_dl: 37, core_ul: 73 },
      { ts: t - 3600, ip: '192.168.1.41', host: 'pixel-8', label: 'Handy WLAN', ping: 3.4, jitter: 1.1, dl: 890, dl_peak: 1020, ul: 610, ul_peak: 700, streams: 4, core_dl: 22, core_ul: 41 },
      { ts: t - 1200, ip: '192.168.1.57', host: 'lg-oled', label: 'SmartTV', ping: 4.1, jitter: 1.6, dl: 410, dl_peak: 468, ul: 220, ul_peak: 251, streams: 4, core_dl: 12, core_ul: 19 }
    ];
  }

  function link(cb, demoPreset) {
    if (demo) {
      demoWifi = demoPreset === 'wifi';
      return setTimeout(function () {
        cb(demoWifi ? { type: 'wifi', port: 'phy1-ap0', speed: null, duplex: null,
                        wifi: { ssid: 'Heimnetz', band: '5', channel: 36, width: 160, standard: 6, signal: -54, noise: -95,
                                tx_rate: 1729, rx_rate: 1441, nss: 2, mcs: 9 } }
                    : { type: 'wired', port: 'lan1', speed: 2500, duplex: 'full', wifi: null });
      }, 30);
    }
    req('GET', API + '/link', null, function (d) { cb(d && d.type ? d : null); });
  }

  window.SpeedEngine = {
    init: function (cb) { init(function (i) { if (i.demo && !demoHistory.length) seedDemoHistory(); cb(i); }); },
    run: start,
    stop: function () { run++; active = false; },
    running: function () { return active; },
    history: function (cb) { if (demo) return cb(demoHistory.slice()); req('GET', API + '/history', null, function (d) { cb(d || []); }); },
    clearHistory: function (cb) { if (demo) { demoHistory = []; return cb([]); } req('DELETE', API + '/history', null, function () { cb([]); }); },
    link: link,
    fmtSpeed: fmtSpeed,
    fmt: fmt
  };
})();
