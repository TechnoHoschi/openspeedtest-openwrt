#!/bin/sh
# Richtet den Speedtest in uhttpd ein. Vorher den Ordner nach /www/speedtest kopieren.
# Aufruf: sh /www/speedtest/install.sh
DIR=/www/speedtest
ENTRY="/speedtest-api=$DIR/api.uc"
BACKUP=/tmp/uhttpd.vor-speedtest

fail() { echo "FEHLER: $*"; exit 1; }

[ -f "$DIR/index.html" ] && [ -f "$DIR/api.uc" ] || fail "Dateien nicht unter $DIR gefunden."
[ -f /usr/lib/uhttpd_ucode.so ] || fail "uhttpd-mod-ucode fehlt. Installieren mit: apk add uhttpd-mod-ucode"
# Ohne fuehrendes {% beendet sich uhttpd beim Start (und LuCI ist weg)
[ "$(head -c 2 "$DIR/api.uc")" = "{%" ] || fail "$DIR/api.uc muss mit {% beginnen (Datei beschaedigt?)."

cp /etc/config/uhttpd "$BACKUP"

uci -q del_list uhttpd.main.ucode_prefix="$ENTRY"
uci add_list uhttpd.main.ucode_prefix="$ENTRY"
# uhttpd laesst standardmaessig nur 3 gleichzeitige Script-Requests zu; Upload mit 8 Verbindungen + CPU-Abfrage braucht mehr
MR=$(uci -q get uhttpd.main.max_requests)
[ -z "$MR" ] || [ "$MR" -lt 16 ] && uci set uhttpd.main.max_requests=16
uci commit uhttpd
service uhttpd restart
sleep 2

if ! pidof uhttpd >/dev/null; then
	echo "uhttpd startet mit dem Speedtest nicht. Stelle die alte Konfiguration wieder her ..."
	cp "$BACKUP" /etc/config/uhttpd
	service uhttpd restart
	fail "Rueckgaengig gemacht. Details: logread | grep uhttpd"
fi

chmod 0644 "$DIR"/*.html "$DIR"/*.txt "$DIR"/api.uc 2>/dev/null

IP=$(uci -q get network.lan.ipaddr | cut -d/ -f1)
[ "$(uci -q get uhttpd.main.redirect_https)" = "1" ] && echo "HINWEIS: uhttpd leitet HTTP auf HTTPS um. Fuer volle Werte abschalten:
  uci set uhttpd.main.redirect_https=0; uci commit uhttpd; service uhttpd restart"
echo "Fertig. Aufruf: http://${IP:-<router-ip>}/speedtest/"
