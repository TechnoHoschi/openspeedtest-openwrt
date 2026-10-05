# LAN-Speedtest für OpenWrt

Ein Browser-Speedtest, den der eingebaute Webserver **uhttpd** (derselbe, der LuCI ausliefert) direkt vom Router bereitstellt.
Gemessen wird die Strecke **Client ↔ Router** über LAN oder WLAN, nicht die Internetleitung.
Läuft auf Desktop, Handy, Tablet und SmartTV, ohne App und ohne Zusatzpakete außer `uhttpd-mod-ucode`.

Früher war das ein Fork von OpenSpeedTest mit Shell-CGIs. Messungen auf einem Asus BT8 haben gezeigt, dass die CGIs der Flaschenhals sind,
deshalb ist das hier ein Neuaufbau (alter Stand: Branch `main` vor dem Neuaufbau, siehe Git-Historie).

## So funktioniert es

| Teil | Umsetzung | Warum |
|---|---|---|
| Download | statische Datei in einem RAM-tmpfs (`/www/speedtest/data/dl.bin`), uhttpd liefert direkt aus | schnellste Variante, kein Flash |
| Upload | ucode-Handler `api.uc` in uhttpd, liest und verwirft die Daten | gut doppelt so schnell wie Shell-CGI |
| Ping/Jitter | kleine Datei `ping.txt`, 20 Abfragen, Median | ohne Script-Overhead |
| Router-CPU | `api.uc` liefert `/proc/stat`, die Seite zeigt Durchschnitt und stärksten Kern | zeigt, ob der Router oder das Netz begrenzt |
| Verlauf | `/tmp/speedtest-history.json` (RAM), max. 200 Einträge, mit Hostname aus der DHCP-Liste und frei wählbarem Gerätenamen | kein Flash-Verschleiß, nach Neustart leer |

Die Download-Datei (64 MB, auf knappen Geräten weniger) legt `api.uc` beim ersten Aufruf der Seite selbst an, auch nach einem Neustart.

Messwerte auf dem Asus BT8 (3 Kerne, PC per 2,5 GbE, Messkit in `bench/`):

| | 1 Verbindung | 4 Verbindungen |
|---|---|---|
| Download, Datei im RAM | 1019 Mbit/s | 1842 Mbit/s |
| Upload, ucode | 599 Mbit/s | 1142 Mbit/s |
| Upload, Shell-CGI (alt) | 319 Mbit/s | 404 Mbit/s |
| iperf3 -P4 (Referenz) | | 2320 / 1710 Mbit/s |

## Voraussetzungen

- OpenWrt 25.12 (getestet: Asus BT8), ab Dual-Core und 128 MB RAM
- `uhttpd-mod-ucode` (ist mit LuCI meist schon da, sonst `apk add uhttpd-mod-ucode`)
- Aufruf über **http://**: HTTPS kostet den Router viel CPU. Ist `redirect_https` aktiv, weist `install.sh` darauf hin.

## Installation

1. Den Ordner `speedtest/` per WinSCP (Protokoll SCP) nach `/www/speedtest` kopieren.
   Mit Kommandozeilen-`scp` die Option `-O` verwenden, dropbear kann kein SFTP.
2. Per SSH: `sh /www/speedtest/install.sh`
3. Im Browser: `http://<router-ip>/speedtest/`

`install.sh` trägt den ucode-Handler in `/etc/config/uhttpd` ein (`ucode_prefix /speedtest-api`), setzt `max_requests` auf mindestens 16
und startet uhttpd neu. Läuft uhttpd danach nicht, stellt das Skript die alte Konfiguration sofort wieder her, damit LuCI erreichbar bleibt.

<details><summary>Dasselbe von Hand (ohne automatischen Rückfall)</summary>

```sh
head -c 2 /www/speedtest/api.uc        # muss "{%" ausgeben, sonst startet uhttpd nicht
cp /etc/config/uhttpd /tmp/uhttpd.bak
uci add_list uhttpd.main.ucode_prefix='/speedtest-api=/www/speedtest/api.uc'
uci set uhttpd.main.max_requests=16
uci commit uhttpd && service uhttpd restart
pidof uhttpd || { cp /tmp/uhttpd.bak /etc/config/uhttpd; service uhttpd restart; }
```
</details>

Für Backups: `/www/speedtest` und `/etc/config/uhttpd` sichern.

## Entfernen

`sh /www/speedtest/uninstall.sh` nimmt den Eintrag aus uhttpd heraus, gibt den RAM frei und löscht den Ordner.

## Hinweise

- **Ping:** uhttpd in OpenWrt 25.12 setzt kein `TCP_NODELAY` und hält dadurch den Rest kleiner Antworten auf einer bestehenden Verbindung ~40 ms zurück
  (behoben in uhttpd [82b4c79](https://github.com/openwrt/uhttpd/commit/82b4c79), in 25.12 noch nicht enthalten). Die Seite misst deshalb die Zeit bis zum ersten Antwort-Byte.
  Aus demselben Grund schickt der Upload große 32-MB-Stücke.
- **Ergebnis:** Groß angezeigt wird die Spitze (bester gleitender 1-s-Wert nach dem Anlauf). Darunter steht der Durchschnitt:
  die 1-s-Werte ohne die langsamsten 30 % und schnellsten 10 %, gemittelt.
- **Diagnose:** `diag.html` vergleicht Ping-, Download- und Upload-Varianten im Browser, falls Werte unplausibel wirken.

- **„Kern max“ nahe 100 %:** Ein Router-Kern war voll ausgelastet. uhttpd bearbeitet eine Verbindung auf einem Kern, mehr Verbindungen können helfen.
- **iperf3** liefert die Referenz fürs Netz, ein Browser kann das Protokoll aber nicht sprechen. Wer es dauerhaft laufen lässt, sollte es mit `-B <lan-ip>` an das LAN binden.
- Ältere Browser ohne Fetch-Streams messen den Download per XHR in 32-MB-Häppchen, damit der Browser-RAM klein bleibt.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
