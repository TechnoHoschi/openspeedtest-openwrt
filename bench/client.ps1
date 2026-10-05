# Messkit, Client-Seite (Windows PowerShell). Aufruf:  .\client.ps1 -Router 192.168.1.252
# Misst jede Variante mit 1 und 4 parallelen Verbindungen und gibt Mbit/s aus.
param([string]$Router = "192.168.1.252", [int]$Runs = 3)

$up = Join-Path $env:TEMP "st-up.bin"
if (-not (Test-Path $up)) { [IO.File]::WriteAllBytes($up, (New-Object byte[] (32MB))) }

function Measure($label, $curlArgs, $streams) {
    $best = 0
    for ($r = 0; $r -lt $Runs; $r++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $out = & curl.exe -s -Z --parallel-max $streams @($curlArgs * $streams) -w "%{size_download} %{size_upload} %{http_code}`n"
        $sw.Stop()
        $bytes = 0; $codes = @()
        foreach ($l in $out) { $p = $l -split ' '; if ($p.Count -ge 3) { $bytes += [double]$p[0] + [double]$p[1]; $codes += $p[2] } }
        $mbit = [math]::Round($bytes * 8 / $sw.Elapsed.TotalSeconds / 1e6)
        if ($mbit -gt $best) { $best = $mbit }
    }
    if (($codes | Where-Object { $_ -ne "200" }).Count -gt 0) { $best = "-" }
    "{0,-28} {1,2} Verb.  {2,6} Mbit/s   HTTP {3}" -f $label, $streams, $best, ($codes | Select-Object -Unique)
}

$b = "http://$Router"
foreach ($s in 1, 4) {
    Measure "A Download statisch/RAM" @("-o", "NUL", "$b/speedtest-bench/data/dl.bin") $s
    Measure "B Download CGI"          @("-o", "NUL", "$b/cgi-bin/bench-dl.cgi") $s
    Measure "C Download ucode"        @("-o", "NUL", "$b/bench-uc") $s
    Measure "B Upload CGI"            @("-o", "NUL", "--data-binary", "@$up", "$b/cgi-bin/bench-up.cgi") $s
    Measure "C Upload ucode"          @("-o", "NUL", "--data-binary", "@$up", "$b/bench-uc") $s
}
