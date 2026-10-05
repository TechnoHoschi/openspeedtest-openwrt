#!/bin/sh
# Messkit: richtet drei Server-Varianten parallel ein, damit wir sie vergleichen koennen.
#   A  statische Datei aus einem RAM-tmpfs   -> /speedtest-bench/data/dl.bin
#   B  Shell-CGI (alter Weg)                 -> /cgi-bin/bench-dl.cgi, /cgi-bin/bench-up.cgi
#   C  ucode-Handler in uhttpd               -> /bench-uc  (GET = Download, POST = Upload)
# Rueckgaengig: sh cleanup.sh
set -e
DIR=/www/speedtest-bench
SIZE_MB=${SIZE_MB:-32}

[ -f /usr/lib/uhttpd_ucode.so ] || echo "WARNUNG: uhttpd-mod-ucode fehlt, Variante C geht nicht"

mkdir -p "$DIR/data"
grep -q " $DIR/data " /proc/mounts || mount -t tmpfs -o size=$((SIZE_MB + 8))m tmpfs "$DIR/data"
dd if=/dev/zero of="$DIR/data/dl.bin" bs=1M count="$SIZE_MB" 2>/dev/null

cat > /www/cgi-bin/bench-dl.cgi <<CGI
#!/bin/sh
printf 'Content-Type: application/octet-stream\r\nContent-Length: %d\r\nCache-Control: no-store\r\n\r\n' $((SIZE_MB * 1048576))
dd if=/dev/zero bs=1M count=$SIZE_MB 2>/dev/null
CGI
cat > /www/cgi-bin/bench-up.cgi <<'CGI'
#!/bin/sh
head -c "${CONTENT_LENGTH:-0}" >/dev/null
printf 'Content-Type: text/plain\r\nCache-Control: no-store\r\n\r\nOK'
CGI
chmod +x /www/cgi-bin/bench-dl.cgi /www/cgi-bin/bench-up.cgi

cat > "$DIR/bench.uc" <<UC
'use strict';
const MB = $SIZE_MB;
let block = null;
global.handle_request = function(env) {
	if (env.REQUEST_METHOD == 'POST') {
		let n = 0, c;
		while ((c = uhttpd.recv(65536)) != null && length(c) > 0)
			n += length(c);
		uhttpd.send('Status: 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\n\r\n' + n);
		return;
	}
	if (block == null) {
		block = 'x';
		while (length(block) < 1048576)
			block += block;
	}
	uhttpd.send('Status: 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ' +
		(MB * 1048576) + '\r\nCache-Control: no-store\r\n\r\n');
	for (let i = 0; i < MB; i++)
		uhttpd.send(block);
};
UC

uci -q del_list uhttpd.main.ucode_prefix="/bench-uc=$DIR/bench.uc" || true
uci add_list uhttpd.main.ucode_prefix="/bench-uc=$DIR/bench.uc"
uci commit uhttpd
service uhttpd restart

echo "Fertig. Redirect auf HTTPS aktiv? -> $(uci -q get uhttpd.main.redirect_https || echo 0)"
echo "CPU: $(grep -c ^processor /proc/cpuinfo) Kerne, RAM frei: $(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo) MB"
