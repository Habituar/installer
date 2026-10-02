<#
  Volta o e-Financeira para a versão anterior (a guardada em <app>\previous\ pela última atualização).
  Execute como Administrador:  powershell -ExecutionPolicy Bypass -File "<app>\scripts\rollback.ps1"

  1. Para o serviço.
  2. Desfaz no BANCO só as migrations que a versão anterior não conhece (dist\scripts\reverterParaVersao.js, com o
     código da versão ATUAL — é ela que tem os down()). Pela política de migrations aditivas, o banco volta a ser
     legível pela versão anterior sem restaurar backup. Se esta etapa falhar, nada mais é feito e o serviço volta a
     subir na versão atual.
  3. Troca os arquivos (backend, frontend, scripts): a versão atual fica em <app>\desfeita-<data>\ para análise.
  4. Sobe o serviço e confere o /health.
  O backup do banco feito antes da atualização continua sendo a garantia final, se algo der errado aqui.
#>
param([switch]$SemConfirmar)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$App      = Split-Path -Parent $PSScriptRoot
$Previous = Join-Path $App 'previous'
$SvcName  = 'efinanceira-api'
$EnvFile  = Join-Path $App 'config\backend.env'
$Node     = Join-Path $App 'node\node.exe'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Execute como Administrador (botão direito no PowerShell > Executar como administrador).'
}
if (-not (Test-Path (Join-Path $Previous 'backend\dist'))) { throw "Não há versão anterior guardada em $Previous." }

$versaoDe = { param($dir) try { (Get-Content (Join-Path $dir 'backend\versao.json') -Raw | ConvertFrom-Json).versao } catch { 'desconhecida' } }
$atual = & $versaoDe $App
$anterior = & $versaoDe $Previous
Write-Host "Versão instalada: $atual  ->  voltar para: $anterior" -ForegroundColor Yellow
if (-not $SemConfirmar) {
  $ok = Read-Host 'Confirma o rollback? (digite SIM)'
  if ($ok -ne 'SIM') { Write-Host 'Cancelado.'; exit 1 }
}

$log = Join-Path $App ("logs\rollback-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $log -Append | Out-Null
try {
  Write-Host '==> Parando o serviço'
  & sc.exe stop $SvcName | Out-Null
  Start-Sleep -Seconds 4

  # Ambiente do backend (segredos DPAPI decifrados só na memória deste processo — como o run-service.ps1)
  Get-Content $EnvFile -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
      $valor = $Matches[2]
      if ($valor -like 'ENC:*') {
        $valor = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($valor.Substring(4)), $null, [Security.Cryptography.DataProtectionScope]::LocalMachine))
      }
      [Environment]::SetEnvironmentVariable($Matches[1], $valor, 'Process')
    }
  }
  $migracoesAnteriores = Join-Path $Previous ("backend\dist\migrations\{0}" -f $env:DB_TYPE)

  Write-Host '==> Banco: desfazendo as migrations que a versão anterior não conhece'
  Push-Location (Join-Path $App 'backend')
  try { & $Node 'dist\scripts\reverterParaVersao.js' $migracoesAnteriores; $rc = $LASTEXITCODE } finally { Pop-Location }
  if ($rc -ne 0) { throw "O rollback do banco falhou (código $rc). Os arquivos NÃO foram trocados; o serviço volta na versão atual." }

  Write-Host '==> Arquivos: restaurando a versão anterior'
  $Desfeita = Join-Path $App ("desfeita-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Path $Desfeita | Out-Null
  foreach ($pasta in 'backend', 'frontend', 'scripts') {
    $destino = Join-Path $App $pasta
    if (Test-Path $destino) { Move-Item $destino (Join-Path $Desfeita $pasta) }
    Copy-Item (Join-Path $Previous $pasta) $destino -Recurse -Force
  }
  Write-Host "Versão desfeita guardada em $Desfeita"
}
catch {
  Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
  $falhou = $true
}
finally {
  Write-Host '==> Subindo o serviço'
  & sc.exe start $SvcName | Out-Null
  Stop-Transcript | Out-Null
}

Start-Sleep -Seconds 8
try {
  $porta = (Get-Content $EnvFile | Where-Object { $_ -like 'PORT=*' } | Select-Object -First 1) -replace 'PORT=', ''
  $saude = Invoke-RestMethod -Uri "http://localhost:$porta/health" -TimeoutSec 15
  Write-Host "Saúde: $($saude.status) | versão em execução: $($saude.versao)" -ForegroundColor Green
} catch { Write-Host "Não foi possível consultar o /health: $($_.Exception.Message)" -ForegroundColor Yellow }
Write-Host "Log: $log"
if ($falhou) { exit 1 } else { exit 0 }
