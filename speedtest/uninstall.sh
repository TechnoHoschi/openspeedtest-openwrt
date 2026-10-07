#!/bin/sh
# Entfernt den Speedtest wieder vollstaendig.
DIR=/www/speedtest
uci -q del_list uhttpd.main.ucode_prefix="/speedtest-api=$DIR/api.uc"
uci commit uhttpd
service uhttpd restart
grep -q " $DIR/data " /proc/mounts && umount "$DIR/data"
rm -rf /tmp/speedtest
rm -f /tmp/speedtest-history.json
rm -rf "$DIR"
echo "Speedtest entfernt. (max_requests von uhttpd bleibt auf dem erhoehten Wert.)"
