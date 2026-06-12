# Adds the inbound firewall rule for the DST dedicated server (run elevated).
# Without this, the headless server never triggers Windows' allow-access prompt,
# inbound discovery packets are dropped, and the server won't appear in the LAN tab.
$exe = "C:\Program Files (x86)\Steam\steamapps\common\Don't Starve Together\bin64\dontstarve_dedicated_server_nullrenderer_x64.exe"
New-NetFirewallRule -DisplayName "DST Dedicated Server (dev)" -Direction Inbound -Program $exe -Action Allow -Profile Any
Write-Host "Firewall rule added." -ForegroundColor Green
Start-Sleep -Seconds 3
