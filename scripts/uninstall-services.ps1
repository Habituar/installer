# Executado pelo desinstalador. Remove o serviço da API e a regra de firewall.
# Não apaga config\, logs\, pgdata\ nem pgsql\ (dados do cliente).
$ErrorActionPreference = 'SilentlyContinue'

$App    = Split-Path -Parent $PSScriptRoot
$SvcExe = Join-Path $App 'services\efinanceira-api.exe'

if (Get-Service 'efinanceira-api') {
  & sc.exe stop 'efinanceira-api' | Out-Null
  Start-Sleep -Seconds 4
  if (Test-Path $SvcExe) { & $SvcExe uninstall | Out-Null }
}

Get-NetFirewallRule -DisplayName 'e-Financeira' | Remove-NetFirewallRule

# O PostgreSQL embutido (serviço efinanceira-pg) e os dados são mantidos de propósito.
# Para remover de vez: <app>\pgsql\uninstall-postgresql.exe e apagar a pasta do app.
exit 0
