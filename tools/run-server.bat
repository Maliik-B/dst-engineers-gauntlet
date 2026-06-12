@echo off
rem Engineer's Gauntlet — local offline dev server (single shard, Master only)
rem Cluster files live at %USERPROFILE%\Documents\Klei\DoNotStarveTogether\EngineersGauntletDev
rem Type Lua directly into this window for server-side console (e.g. c_gauntlet()).
rem c_shutdown() saves and stops the server cleanly.

set "DST_BIN=C:\Program Files (x86)\Steam\steamapps\common\Don't Starve Together\bin64"
cd /d "%DST_BIN%"
dontstarve_dedicated_server_nullrenderer_x64.exe -console -cluster EngineersGauntletDev -shard Master
pause
