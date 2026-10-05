# Messkit: welche Server-Variante ist auf dem Router am schnellsten?

Vergleicht drei Wege, wie uhttpd Testdaten liefern und annehmen kann:

| | Variante | Download | Upload |
|---|---|---|---|
| A | statische Datei in einem RAM-tmpfs | ja | – |
| B | Shell-CGI (bisheriger Weg) | ja | ja |
| C | ucode-Handler in uhttpd | ja | ja |

## Ablauf

1. `setup.sh` und `cleanup.sh` per WinSCP nach `/tmp/` auf den Router kopieren.
2. Per SSH: `sh /tmp/setup.sh`
3. Parallel eine zweite SSH-Sitzung mit `top -d 1` offen lassen und die CPU-Last beobachten.
4. Auf dem Windows-PC (PowerShell, im Ordner mit `client.ps1`):
   `powershell -ExecutionPolicy Bypass -File .\client.ps1 -Router 192.168.1.252`
5. Danach auf dem Router: `sh /tmp/cleanup.sh`

Am besten einmal per LAN-Kabel und einmal per WLAN messen.
Optional als Referenz, falls `iperf3.exe` auf dem PC vorhanden ist:
Router `iperf3 -s -1`, PC `iperf3 -c 192.168.1.252 -P 4` und `... -P 4 -R`.
