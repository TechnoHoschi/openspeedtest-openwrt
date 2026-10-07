# LAN-Speedtest für OpenWrt · Silizium

Ein Browser-Speedtest, den der eingebaute Webserver **uhttpd** (derselbe, der LuCI ausliefert) direkt vom Router bereitstellt.
Gemessen wird die Strecke **Gerät ↔ Router** über LAN oder WLAN, nicht die Internetleitung.
Läuft auf Desktop, Handy, Tablet und SmartTV, ohne App und ohne Zusatzpakete außer `uhttpd-mod-ucode`.

Die Oberfläche heißt **Silizium**: Die Messung läuft als Lichtimpulse über eine nachgebaute Router-Platine,
von der LAN-Buchse, an der das Gerät wirklich hängt, über den Switch zum SoC oder über den WLAN-Chip zu den Antennen.

> **Zu 99 % Vibe-Coding.** Code, Designs und Texte dieses Repos hat eine KI geschrieben (Claude Code).
> Der Mensch hat Ziele vorgegeben, auf dem echten Router gemessen, Ergebnisse zurückgemeldet, gestaunt und gelegentlich gesagt,
> dass die Kamera nicht so nah ran soll. Das restliche Prozent: Debugging am Gerät und der KI auf die Sprünge helfen,
> wenn sie vom Weg abgekommen ist. Das ist nicht zu unterschätzen. ;)

## Was wird gemessen?

> ⚠️ Gemessen wird zwischen Browser und **LAN-Schnittstelle des Routers**, nicht die Internetgeschwindigkeit.
> Für die Internetleitung gibt es andere Dienste.

Damit siehst du, ob WLAN, Kabel, Switch-Port, Gerät oder der Router selbst der Engpass ist:

- **Ping und Jitter** zum Router
- **Download und Upload**, jeweils Spitze (bester 1-s-Wert) und Durchschnitt
- **Router-CPU je Kern**, damit klar ist, ob der Router oder das Netz begrenzt
- **Anschluss**: welcher LAN-Port mit welcher Geschwindigkeit, bzw. WLAN-Band, Kanal, Signal und Linkrate (meldet der Router selbst)
- **Verlauf** aller Messungen mit Hostname aus der DHCP-Liste und frei wählbarem Gerätenamen

## Drei Ansichten, eine Adresse

`http://<router-ip>/speedtest/` öffnet `index.html`. Die Seite prüft, was der Browser flüssig darstellen kann, und lädt dann:

| Ansicht | Datei | Für wen | Darstellung |
|---|---|---|---|
| **3D** | `silizium3d.html` | Geräte mit Grafikkarten-WebGL und mindestens 4 Kernen | Platine als 3D-Körper (WebGL), im Leerlauf fliegt eine Drohnenkamera darüber, bei der Messung schräge Draufsicht |
| **2D** | `silizium2d.html` | alles dazwischen | animierte Platine (Canvas), Kamera zoomt und dreht leicht |
| **Lite** | `silizium-lite.html` | alte oder schwache Geräte, ältere SmartTVs, „Bewegung reduzieren“ | keine Animation, kein Canvas, nur einfaches CSS, 25 KB |

In jeder Ansicht kann man unten mit **Lite · 2D · 3D** wechseln, die Wahl wird im Browser gemerkt.
Kann ein Gerät 3D doch nicht darstellen, springt die Seite selbst auf 2D zurück.
Alle drei zeigen dieselben Messwerte und am Ende dasselbe **Messprotokoll**.

Schriften (Saira, Share Tech Mono) sind in 2D und 3D eingebettet, alles läuft ohne Internet.

## So funktioniert es

| Teil | Umsetzung | Warum |
|---|---|---|
| Download | statische Datei in `/tmp/speedtest` (RAM), per Bind-Mount unter `/www/speedtest/data/` eingeblendet, uhttpd liefert direkt aus | schnellste Variante, kein Flash |
| Upload | ucode-Handler `api.uc` in uhttpd, liest und verwirft die Daten | gut doppelt so schnell wie Shell-CGI |
| Ping/Jitter | kleine Datei `ping.txt`, 20 Abfragen, Median | ohne Script-Overhead |
| Messkern | `engine.js`, ES5 ohne Abhängigkeiten, gemeinsam für alle Ansichten; ohne Router läuft ein Demo-Modus | ein Messkern, viele Oberflächen |
| Router-CPU | `/speedtest-api/cpu` liefert `/proc/stat`, gelesen am Anfang und Ende jeder Richtung | zeigt, ob der Router oder das Netz begrenzt |
| Anschluss | `/speedtest-api/link`: IP → MAC (ARP) → Bridge-Port → Port-Speed, bei WLAN Band/Kanal/Signal/Linkrate über iwinfo | die Platine zeigt den echten Datenweg |
| Router-Info | `/speedtest-api/info`: Hostname, Modell, Kerne und SoC aus dem Device-Tree (z. B. MediaTek MT7988A, Filogic 880) | Aufdruck auf dem Chip |
| Verlauf | `/tmp/speedtest-history.json` (RAM), max. 200 Einträge | kein Flash-Verschleiß, nach Neustart leer |

Die Download-Datei (64 MB, auf knappen Geräten weniger) legt `api.uc` beim ersten Aufruf der Seite selbst an, auch nach einem Neustart.

Messwerte auf dem Asus BT8 (3 Kerne, PC per 2,5 GbE, Messkit in `bench/`):

| | 1 Verbindung | 4 Verbindungen |
|---|---|---|
| Download, Datei im RAM | 1019 Mbit/s | 1842 Mbit/s |
| Upload, ucode | 599 Mbit/s | 1142 Mbit/s |
| Upload, Shell-CGI (alt) | 319 Mbit/s | 404 Mbit/s |
| iperf3 -P4 (Referenz) | | 2320 / 1710 Mbit/s |

Im Browser (Chrome, Kabel) erreicht die Seite auf dem BT8 bis 2,39 Gbit/s Download und 1,0 bis 1,4 Gbit/s Upload bei 2 ms Ping.

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

**Aktualisieren:** neue Dateien nach `/www/speedtest` kopieren. Nach Änderungen an `api.uc` zusätzlich `service uhttpd restart`
(vorher prüfen: `head -c 2 /www/speedtest/api.uc` muss `{%` ausgeben).

Für Backups: `/www/speedtest` und `/etc/config/uhttpd` sichern.

## Entfernen

`sh /www/speedtest/uninstall.sh` nimmt den Eintrag aus uhttpd heraus, gibt den RAM frei und löscht den Ordner.

## Dateien in `speedtest/`

| Datei | Zweck |
|---|---|
| `index.html` | Einstieg, wählt Lite, 2D oder 3D |
| `silizium-lite.html`, `silizium2d.html`, `silizium3d.html` | die drei Ansichten |
| `engine.js` | Messkern |
| `api.uc` | ucode-API für uhttpd (`/up`, `/cpu`, `/info`, `/link`, `/history`) |
| `install.sh`, `uninstall.sh` | Einrichten und Entfernen |
| `ping.txt` | Ziel der Ping-Messung |
| `diag.html` | Diagnose: Browser-Methoden im Vergleich, falls Werte unplausibel wirken |
| `referenz.html` | schlichte technische Referenzseite |
| alle übrigen `*.html` | Design-Entwürfe aus der Entstehung (Tacho, Cockpit, Warp, Fusionskern, Beschleuniger, Netzatlas, Datenrelief und viele mehr), funktionsfähig und direkt aufrufbar |

## Hinweise

- **Ping:** uhttpd in OpenWrt 25.12 setzt kein `TCP_NODELAY` und hält dadurch den Rest kleiner Antworten auf einer bestehenden Verbindung ~40 ms zurück
  (behoben in uhttpd [82b4c79](https://github.com/openwrt/uhttpd/commit/82b4c79), in 25.12 noch nicht enthalten). Die Seite misst deshalb die Zeit bis zum ersten Antwort-Byte.
  Aus demselben Grund schickt der Upload große 32-MB-Stücke.
- **Ergebnis:** Groß angezeigt wird die Spitze (bester gleitender 1-s-Wert, derselbe Wert, den die Live-Anzeige zeigt). Darunter steht der Durchschnitt:
  die 1-s-Werte ohne die langsamsten 30 % und schnellsten 10 %, gemittelt.
- **Ein CPU-Kern nahe 100 %:** Dann zeigt das Ergebnis eher die Grenze des Routers als die des Netzes. Beim Speedtest ist der Router selbst die Gegenstelle;
  Verkehr, der durch den Router läuft, nutzt Hardware-Beschleunigung und ist meist schneller.
- **iperf3** liefert die Referenz fürs Netz, ein Browser kann das Protokoll aber nicht sprechen. Wer es dauerhaft laufen lässt, sollte es mit `-B <lan-ip>` an das LAN binden.
- Ältere Browser ohne Fetch-Streams messen den Download per XHR in 32-MB-Häppchen, damit der Browser-RAM klein bleibt.

## Danke

Dieses Projekt hat als Fork von **[OpenSpeedTest™](https://openspeedtest.com)** angefangen
([github.com/openspeedtest/Speed-Test](https://github.com/openspeedtest/Speed-Test)).
OpenSpeedTest hat gezeigt, wie gut ein Speedtest nur mit Bordmitteln des Browsers funktionieren kann, und war der Ausgangspunkt für alles hier.
Herzlichen Dank an Vishnu und das OpenSpeedTest-Team sowie an alle, die dort beigetragen haben!

Inzwischen ist der Code komplett neu aufgebaut. Der alte Fork-Stand mit den Shell-CGIs steckt in der Git-Historie.

Danke außerdem an das **OpenWrt**-Projekt für uhttpd, ucode, LuCI und iwinfo, auf denen der Speedtest aufsetzt,
und an die Gestalter der Schriften **Saira** (Omnibus-Type) und **Share Tech Mono** (Carrois Apostrophe), beide unter der SIL Open Font License.

## Lizenz

MIT, siehe [LICENSE](LICENSE). Die eingebetteten Schriften stehen unter der SIL Open Font License 1.1.
