<#
  Atualização: antes de os arquivos novos serem copiados, guarda a versão EM USO em <app>\previous\ (backend,
  frontend, scripts e a definição do serviço). É o que o rollback.ps1 restaura. Só a última versão anterior é mantida.
  Chamado pelo instalador (PrepareToInstall) — se falhar, a atualização é cancelada antes de mexer em qualquer arquivo.
#>
param([Parameter(Mandatory = $true)][string]$App)
$ErrorActionPreference = 'Stop'

$Previous = Join-Path $App 'previous'
$Temp = "$Previous.novo"
if (Test-Path $Temp) { Remove-Item $Temp -Recurse -Force }
New-Item -ItemType Directory -Path $Temp | Out-Null

foreach ($pasta in 'backend', 'frontend', 'scripts') {
  $origem = Join-Path $App $pasta
  if (Test-Path $origem) { Copy-Item $origem (Join-Path $Temp $pasta) -Recurse -Force }
}
$servicos = Join-Path $App 'services'
if (Test-Path $servicos) {
  New-Item -ItemType Directory -Path (Join-Path $Temp 'services') | Out-Null
  Get-ChildItem $servicos -Filter *.xml | Copy-Item -Destination (Join-Path $Temp 'services')
}

$versao = 'desconhecida'
$arquivoVersao = Join-Path $App 'backend\versao.json'
if (Test-Path $arquivoVersao) { try { $versao = (Get-Content $arquivoVersao -Raw | ConvertFrom-Json).versao } catch { } }
@"
Versão guardada: $versao
Guardada em: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Para voltar a esta versão: execute, como Administrador, scripts\rollback.ps1 (na pasta de instalação).
"@ | Set-Content (Join-Path $Temp 'LEIA-ME.txt') -Encoding UTF8

# Troca atômica o suficiente: a versão anterior só é substituída depois de a nova cópia estar completa
if (Test-Path $Previous) { Remove-Item $Previous -Recurse -Force }
Rename-Item $Temp 'previous'
Write-Host "Versão $versao guardada em $Previous"
exit 0
