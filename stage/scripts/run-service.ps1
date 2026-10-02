<#
  Processo real do serviço do Windows "efinanceira-api" — é isto que o WinSW lança, não o node.exe direto.
  config\backend.env guarda os segredos cifrados via DPAPI (LocalMachine) — este script decifra e
  passa pro processo do Node como variável de ambiente. Os segredos existem em texto puro só na
  memória deste processo (e do node.exe que ele lança em seguida), nunca gravados em disco.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$App        = Split-Path -Parent $PSScriptRoot
$EnvFile    = Join-Path $App 'config\backend.env'
$Node       = Join-Path $App 'node\node.exe'
$BackendDir = Join-Path $App 'backend'
$entry      = (Get-Content (Join-Path $BackendDir 'entry.txt') -Raw).Trim()

function Unprotect-Secret {
  param([string]$Value)
  if ($Value -notlike 'ENC:*') { return $Value }
  $bytes = [Convert]::FromBase64String($Value.Substring(4))
  $plain = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
  return [Text.Encoding]::UTF8.GetString($plain)
}

Get-Content $EnvFile -Encoding UTF8 | ForEach-Object {
  if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
    [Environment]::SetEnvironmentVariable($Matches[1], (Unprotect-Secret $Matches[2]), 'Process')
  }
}

# Pasta dos logs do WinSW: o pacote de diagnóstico (GET /api/configuracoes/diagnostico) lê os mais recentes daqui
$env:LOG_DIR = Join-Path $App 'logs'
Set-Location $BackendDir
& $Node $entry
exit $LASTEXITCODE
