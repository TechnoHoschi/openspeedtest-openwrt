#!/bin/sh
# Entfernt alles, was setup.sh angelegt hat.
DIR=/www/speedtest-bench
uci -q del_list uhttpd.main.ucode_prefix="/bench-uc=$DIR/bench.uc"
uci commit uhttpd
service uhttpd restart
grep -q " $DIR/data " /proc/mounts && umount "$DIR/data"
rm -rf "$DIR" /www/cgi-bin/bench-dl.cgi /www/cgi-bin/bench-up.cgi
echo "Aufgeraeumt."
