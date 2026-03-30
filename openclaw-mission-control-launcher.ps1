Set-StrictMode -Version Latest

$env:OPENCLAW_GATEWAY_URL = 'ws://127.0.0.1:18789'
$env:OPENCLAW_AUTH_TOKEN = 'EAtYSDB2YfZICvJWkJ1OLIKWGLNWoK2151y/7gLtjo6KKuAfw0jfGMOCQJ4UFqUT'
$env:OPENCLAW_STATE_DIR = 'C:\Users\RickQ\.openclaw'
$env:PORT = '3000'

Set-Location 'E:\projects\clawbot\openclaw-mission-control-src'
& 'C:\Program Files\nodejs\node.exe' 'E:\projects\clawbot\openclaw-mission-control-src\.next\standalone\server.js' *>> 'C:\Users\RickQ\.openclaw\logs\mission-control-standalone.log'
