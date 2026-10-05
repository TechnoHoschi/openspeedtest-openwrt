{%
// Speedtest-API fuer uhttpd (ucode_prefix /speedtest-api)
// Wichtig: die Datei muss mit "{%" beginnen, sonst beendet sich uhttpd beim Start.
'use strict';

const fs = require('fs');

const WWW = '/www/speedtest';
const DATA = WWW + '/data';
const DL_FILE = DATA + '/dl.bin';
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

// Download-Datei im RAM (tmpfs) anlegen, falls noch nicht da (z. B. nach Neustart).
// Groesse: 64 MB, auf knappen Geraeten weniger.
function prepare() {
	let mb = 64;
	let avail = mem_available_mb();
	while (mb > 8 && mb * 4 > avail)
		mb /= 2;
	let st = fs.stat(DL_FILE);
	if (st && st.size >= 8 * 1048576)
		return st.size;
	let mounts = read('/proc/mounts') || '';
	if (index(mounts, ' ' + DATA + ' ') < 0) {
		fs.mkdir(DATA);
		system(sprintf("mount -t tmpfs -o size=%dm,mode=0755 tmpfs '%s'", mb + 1, DATA));
	}
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
