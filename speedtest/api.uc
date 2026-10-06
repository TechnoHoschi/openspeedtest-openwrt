{%
// Speedtest-API fuer uhttpd (ucode_prefix /speedtest-api)
// Wichtig: die Datei muss mit "{%" beginnen, sonst beendet sich uhttpd beim Start.
'use strict';

const fs = require('fs');

const WWW = '/www/speedtest';
const DATA = WWW + '/data';
const DL_FILE = DATA + '/dl.bin';
const RAM_DIR = '/tmp/speedtest';
const HISTORY = '/tmp/speedtest-history.json';
const HISTORY_MAX = 200;

function reply(status, type, body) {
	uhttpd.send('Status: ' + status + '\r\nContent-Type: ' + type +
		'\r\nCache-Control: no-store\r\n\r\n' + body);
}

function reply_json(obj) {
	reply('200 OK', 'application/json', sprintf('%J', obj));
}

function read(path) {
	let f = fs.open(path, 'r');
	if (!f)
		return null;
	let s = f.read('all');
	f.close();
	return s;
}

function mem_available_mb() {
	let m = match(read('/proc/meminfo') || '', /MemAvailable:\s+(\d+)/);
	return m ? int(m[1]) / 1024 : 0;
}

function cpu_times() {
	let out = [];
	for (let line in split(read('/proc/stat') || '', '\n')) {
		let m = match(line, /^cpu(\d*)\s+(.*)$/);
		if (!m)
			continue;
		let v = map(split(trim(m[2]), /\s+/), (x) => int(x));
		let total = 0;
		for (let x in v)
			total += x;
		// idle + iowait zaehlen als "frei"
		push(out, [ total, v[3] + (v[4] || 0) ]);
	}
	return out;   // [0] = gesamt, [1..] = einzelne Kerne
}

function client_name(ip) {
	for (let line in split(read('/tmp/dhcp.leases') || '', '\n')) {
		let f = split(line, ' ');
		if (length(f) >= 4 && f[2] == ip && f[3] != '*')
			return f[3];
	}
	return null;
}

// ---------- Verbindung des Geraets: Kabel-Port oder WLAN ----------
// Weg: IP -> MAC (ARP-Tabelle) -> Bridge-Port (brforward) -> Port-Speed bzw. WLAN-Daten (iwinfo per ubus).
// Alles optional: was fehlt, bleibt null, die Seite schaetzt dann aus den Messwerten.
const NET = '/sys/class/net/';

function arp_lookup(ip) {
	for (let line in split(read('/proc/net/arp') || '', '\n')) {
		let f = split(trim(line), /\s+/);
		if (length(f) >= 6 && f[0] == ip && f[3] != '00:00:00:00:00:00')
			return { mac: lc(f[3]), dev: f[5] };
	}
	return null;
}

// /sys/class/net/<br>/brforward: Eintraege zu je 16 Byte (mac[6], port_no, is_local, ageing[4], port_hi, pad, unused[2])
function bridge_port(br, mac) {
	let s = read(NET + br + '/brforward');
	if (!s)
		return null;
	let no = null;
	for (let i = 0; i + 16 <= length(s); i += 16) {
		let m = join(':', map([0, 1, 2, 3, 4, 5], (k) => sprintf('%02x', ord(s, i + k))));
		if (m == mac && ord(s, i + 7) == 0) {
			no = ord(s, i + 6) | (ord(s, i + 12) << 8);
			break;
		}
	}
	if (no == null)
		return null;
	for (let p in fs.lsdir(NET + br + '/brif') || []) {
		if (hex(trim(read(NET + br + '/brif/' + p + '/port_no') || '')) == no)
			return p;
	}
	return null;
}

function is_wifi(dev) {
	return !!(fs.stat(NET + dev + '/wireless') || fs.stat(NET + dev + '/phy80211'));
}

function wifi_info(dev, mac) {
	let ubus = null, c = null;
	try { ubus = require('ubus'); c = ubus.connect(); } catch (e) { }
	if (!c)
		return null;
	let w = { ssid: null, band: null, channel: null, width: null, standard: null,
		signal: null, noise: null, tx_rate: null, rx_rate: null, nss: null, mcs: null };
	let i = c.call('iwinfo', 'info', { device: dev });
	if (i) {
		w.ssid = i.ssid;
		w.channel = i.channel;
		let f = i.frequency || 0;
		w.band = f >= 5925 ? '6' : (f >= 4900 ? '5' : (f > 0 ? '2.4' : null));
		let m = match(i.htmode || '', /^(EHT|HE|VHT|HT)(\d+)/);
		if (m) {
			w.width = int(m[2]);
			w.standard = { EHT: 7, HE: 6, VHT: 5, HT: 4 }[m[1]];
		}
	}
	let a = c.call('iwinfo', 'assoclist', { device: dev });
	for (let s in (a && a.results) || []) {
		if (lc(s.mac || '') != mac)
			continue;
		w.signal = s.signal;
		w.noise = s.noise;
		if (s.tx) {
			w.tx_rate = s.tx.rate ? s.tx.rate / 1000 : null;
			w.nss = s.tx.nss || null;
			w.mcs = s.tx.mcs;
			if (s.tx.mhz)
				w.width = s.tx.mhz;
		}
		if (s.rx)
			w.rx_rate = s.rx.rate ? s.rx.rate / 1000 : null;
		break;
	}
	c.disconnect();
	return w;
}

function link_info(ip) {
	let r = { type: null, port: null, speed: null, duplex: null, wifi: null };
	let a = arp_lookup(ip);
	if (!a)
		return r;
	let port = fs.stat(NET + a.dev + '/bridge') ? bridge_port(a.dev, a.mac) : a.dev;
	if (!port)
		return r;
	r.port = port;
	if (is_wifi(port)) {
		r.type = 'wifi';
		r.wifi = wifi_info(port, a.mac);
	}
	else {
		r.type = 'wired';
		let sp = int(trim(read(NET + port + '/speed') || ''));
		r.speed = (sp > 0) ? sp : null;   // -1 bei unbekannter Geschwindigkeit
		r.duplex = trim(read(NET + port + '/duplex') || '') || null;
	}
	return r;
}

// Download-Datei liegt in /tmp (RAM), nie im Flash. uhttpd liefert nur Dateien
// innerhalb von /www aus (Symlinks nach draussen lehnt es ab), deshalb wird
// /tmp/speedtest per Bind-Mount unter /www/speedtest/data eingeblendet.
// Groesse: 64 MB, auf knappen Geraeten weniger. Nach einem Neustart neu angelegt.
function mounted() {
	return index(read('/proc/mounts') || '', ' ' + DATA + ' ') >= 0;
}

function prepare() {
	if (!mounted()) {
		// Reste aus aelteren Versionen im Flash entfernen
		fs.unlink(DL_FILE);
		fs.mkdir(DATA);
		fs.mkdir(RAM_DIR);
		system(sprintf("mount -o bind '%s' '%s'", RAM_DIR, DATA));
		if (!mounted())
			return 0;   // lieber ohne Testdatei als in den Flash schreiben
	}
	let st = fs.stat(DL_FILE);
	if (st && st.size >= 8 * 1048576)
		return st.size;
	let mb = 64;
	let avail = mem_available_mb();
	while (mb > 8 && mb * 4 > avail)
		mb /= 2;
	system(sprintf("dd if=/dev/zero of='%s.tmp' bs=1048576 count=%d 2>/dev/null && mv '%s.tmp' '%s'",
		DL_FILE, mb, DL_FILE, DL_FILE));
	st = fs.stat(DL_FILE);
	return st ? st.size : 0;
}

function load_history() {
	let s = read(HISTORY), h = null;
	try { h = s ? json(s) : null; } catch (e) { }
	return type(h) == 'array' ? h : [];
}

function num(v) {
	if (type(v) != 'int' && type(v) != 'double')
		return null;
	return (v == v && v >= 0 && v < 1e7) ? v : null;   // v == v filtert NaN
}

function save(env, body) {
	let r = null;
	try { r = json(body); } catch (e) { }
	if (type(r) != 'object')
		return reply('400 Bad Request', 'text/plain', 'bad json');
	let label = (type(r.label) == 'string') ? substr(trim(r.label), 0, 40) : '';
	let ip = env.REMOTE_ADDR;
	let entry = {
		ts: time(),
		ip: ip,
		host: client_name(ip),
		label: label,
		ping: num(r.ping), jitter: num(r.jitter),
		dl: num(r.dl), ul: num(r.ul),
		dl_peak: num(r.dl_peak), ul_peak: num(r.ul_peak),
		streams: num(r.streams),
		cpu_dl: num(r.cpu_dl), cpu_ul: num(r.cpu_ul),
		core_dl: num(r.core_dl), core_ul: num(r.core_ul)
	};
	let h = load_history();
	push(h, entry);
	if (length(h) > HISTORY_MAX)
		h = slice(h, length(h) - HISTORY_MAX);
	let f = fs.open(HISTORY + '.tmp', 'w');
	if (f) {
		f.write(sprintf('%J', h));
		f.close();
		fs.rename(HISTORY + '.tmp', HISTORY);
	}
	reply_json(entry);
}

function read_body(limit) {
	let body = '', c;
	while ((c = uhttpd.recv(4096)) != null && length(c) > 0) {
		if (length(body) < limit)
			body += c;
	}
	return body;
}

global.handle_request = function(env) {
	let path = env.PATH_INFO;
	if (path == null) {
		path = replace(env.REQUEST_URI || '', /^\/speedtest-api/, '');
		path = replace(path, /\?.*$/, '');
	}
	let method = env.REQUEST_METHOD;

	if (path == '/up' && method == 'POST') {
		// Upload-Daten lesen und verwerfen
		let n = 0, c;
		while ((c = uhttpd.recv(65536)) != null && length(c) > 0)
			n += length(c);
		return reply('200 OK', 'text/plain', '' + n);
	}

	if (path == '/cpu')
		return reply_json(cpu_times());

	if (path == '/link') {
		let r = null;
		try { r = link_info(env.REMOTE_ADDR); } catch (e) { }
		return reply_json(r || { type: null });
	}

	if (path == '/info') {
		let ip = env.REMOTE_ADDR;
		let size = prepare();
		return reply_json({
			hostname: trim(read('/proc/sys/kernel/hostname') || ''),
			model: trim(read('/tmp/sysinfo/model') || ''),
			cores: length(cpu_times()) - 1,
			client_ip: ip,
			client_host: client_name(ip),
			dl_url: '/speedtest/data/dl.bin',
			dl_size: size
		});
	}

	if (path == '/history') {
		if (method == 'POST')
			return save(env, read_body(4096));
		if (method == 'DELETE') {
			fs.unlink(HISTORY);
			return reply_json([]);
		}
		return reply_json(load_history());
	}

	reply('404 Not Found', 'text/plain', 'not found');
};
