<#
  Gera o instalador do e-Financeira On-Premise (Windows Server).

  Rode numa máquina Windows x64 com Node 22 e Inno Setup 6.3+, a partir da pasta que contém
  efinanceira-back, efinanceira-front e installer:

      powershell -ExecutionPolicy Bypass -File installer\build.ps1 -Version 1.0.0
      powershell -ExecutionPolicy Bypass -File installer\build.ps1 -Version 1.0.0 -SemPostgres   (sem PostgreSQL)

  -Version é a ÚNICA fonte da versão (obrigatória, formato X.Y.Z): vai para o versao.json do backend (lido pelo
  /health, pelo verAplic dos eventos e pelo diagnóstico), para o "version" do package.json empacotado e para o
  AppVersion do instalador. Não há versão digitada em nenhum outro lugar.

  Antes da primeira vez: node installer\tools\gerar-chaves-licenca.mjs (gera installer\license-public.pem).
  Precisa ser Windows porque módulos nativos baixam binários específicos da plataforma;
  o que for empacotado é o que roda no cliente.

  deps\ e stage\ NÃO são versionados: deps\ (zip do Node, WinSW, instalador do PostgreSQL) é baixado dos endereços
  oficiais quando falta, e stage\ é recriado do zero a cada build. Só preparar deps\ (sem gerar nada):
      powershell -ExecutionPolicy Bypass -File installer\build.ps1 -SoDependencias [-SemPostgres]
#>
param(
  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version,                # obrigatória para gerar o instalador; dispensada com -SoDependencias
  [string]$BackendDir     = "efinanceira-back",
  [string]$FrontendDir    = "efinanceira-front",
  [string]$LicensePublicKey = "",   # PEM da chave PUBLICA (padrao: installer\license-public.pem) — so para conferir config\global-defaults.env
  [string]$NodeVersion    = "22.14.0",
  [string]$PgInstallerUrl = "https://get.enterprisedb.com/postgresql/postgresql-16.4-1-windows-x64.exe",
  [string]$WinSWUrl       = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe",
  [switch]$SemPostgres,   # instalador sem PostgreSQL (so SQL Server ou Oracle existentes): nao baixa nem embute o PostgreSQL
  [switch]$SoDependencias # so baixa/confere deps\ e sai (nao exige back/front/Inno Setup, nao gera instalador)
)
if (-not $SoDependencias -and -not $Version) { throw "Informe -Version X.Y.Z (ex.: -Version 1.2.27)." }

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$Installer = $PSScriptRoot
if (-not $LicensePublicKey) { $LicensePublicKey = Join-Path $PSScriptRoot 'license-public.pem' }
$Root      = Split-Path -Parent $Installer
$Deps      = Join-Path $Installer 'deps'
$Stage     = Join-Path $Installer 'stage'
$Backend   = Join-Path $Root $BackendDir
$Frontend  = Join-Path $Root $FrontendDir

function Invoke-Checked {
  param([string]$Exe, [string[]]$ArgList)
  & $Exe @ArgList
  if ($LASTEXITCODE -ne 0) { throw "Falhou: $Exe $($ArgList -join ' ') (código $LASTEXITCODE)" }
}

# Dependência externa em deps\ (não versionada): usa a que já estiver lá; senão baixa do endereço oficial. Baixa para
# <arquivo>.part e só renomeia no fim — antes um download interrompido deixava um arquivo pela metade que os builds
# seguintes tratavam como "em cache". Sem internet: coloque o arquivo em deps\ à mão (README, "Dependências externas").
function Get-Dep {
  param([string]$Url, [string]$Dest, [string]$Sha256Url)
  $nome = Split-Path -Leaf $Dest
  if (Test-Path $Dest) {
    if ((Get-Item $Dest).Length -gt 0) { Write-Host "  em cache: $nome"; return }
    Remove-Item $Dest -Force   # arquivo vazio de uma tentativa antiga
  }
  $parcial = "$Dest.part"
  Write-Host "  baixando $Url"
  try {
    Invoke-WebRequest -Uri $Url -OutFile $parcial -UseBasicParsing
    if ((Get-Item $parcial).Length -eq 0) { throw 'o servidor devolveu um arquivo vazio' }
    if ($Sha256Url) {   # soma oficial publicada junto do arquivo (ex.: SHASUMS256.txt do nodejs.org)
      $somas = (Invoke-WebRequest -Uri $Sha256Url -UseBasicParsing).Content
      $esperado = ([regex]::Match($somas, "(?m)^([0-9a-f]{64})\s+$([regex]::Escape($nome))\s*$")).Groups[1].Value
      if (-not $esperado) { throw "$nome não consta em $Sha256Url" }
      $obtido = (Get-FileHash $parcial -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($obtido -ne $esperado) { throw "SHA-256 não confere (esperado $esperado, obtido $obtido)" }
      Write-Host "  SHA-256 conferido: $nome"
    }
    Move-Item $parcial $Dest -Force
  } catch {
    if (Test-Path $parcial) { Remove-Item $parcial -Force }
    throw "Não consegui obter $nome de $Url ($($_.Exception.Message)). Sem internet nesta máquina? Baixe o arquivo em " +
      "outra e coloque-o em $Dest (ver README, seção `"Dependências externas`")."
  }
}

function Get-Dependencias {
  Write-Host "==> Dependências externas (deps\)"
  New-Item -ItemType Directory -Force -Path $Deps | Out-Null
  Get-Dep "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-win-x64.zip" (Join-Path $Deps "node-v$NodeVersion-win-x64.zip") `
    "https://nodejs.org/dist/v$NodeVersion/SHASUMS256.txt"
  Get-Dep $WinSWUrl (Join-Path $Deps 'WinSW-x64.exe')
  if (-not $SemPostgres) { Get-Dep $PgInstallerUrl (Join-Path $Deps 'postgresql-installer.exe') }
}

# Só prepara deps\ (máquina sem internet, ou conferir antes do build): não exige back/front/Inno Setup nem gera nada
if ($SoDependencias) { Get-Dependencias; Write-Host "deps\ pronta: $Deps" -ForegroundColor Green; exit 0 }

# ---------------------------------------------------------------- pré-checagem
$iscc = @(
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 não encontrado. Instale em https://jrsoftware.org/isdl.php" }
if (-not (Test-Path (Join-Path $Backend 'package.json')))  { throw "Backend não encontrado em $Backend (use -BackendDir)" }
if (-not (Test-Path (Join-Path $Frontend 'package.json'))) { throw "Frontend não encontrado em $Frontend (use -FrontendDir)" }
# Valores globais fixos (LICENSE_PUBLIC_KEY_B64, CERT_SERVIDOR_RFB, ...): vão como estão para o backend.env
$GlobalDefaults = Join-Path $Installer 'config\global-defaults.env'
if (-not (Test-Path $GlobalDefaults)) { throw "Arquivo de valores globais não encontrado: $GlobalDefaults" }
$globals = @{}
Get-Content $GlobalDefaults -Encoding UTF8 | ForEach-Object {
  if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $globals[$Matches[1]] = $Matches[2].TrimEnd() }
}
foreach ($k in 'LICENSE_PUBLIC_KEY_B64', 'CERT_SERVIDOR_RFB') {
  if (-not $globals[$k]) { throw "$k ausente ou vazio em $GlobalDefaults" }
}
$licPem = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($globals['LICENSE_PUBLIC_KEY_B64']))
if ($licPem -match 'PRIVATE KEY') { throw "LICENSE_PUBLIC_KEY_B64 em $GlobalDefaults contém uma chave PRIVADA. Use apenas a chave pública no instalador." }
if (Test-Path $LicensePublicKey) {   # par regerado e global-defaults.env esquecido = toda licença recusada no cliente
  $pemB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Content $LicensePublicKey -Raw)))
  if ($pemB64 -ne $globals['LICENSE_PUBLIC_KEY_B64']) {
    throw "LICENSE_PUBLIC_KEY_B64 em $GlobalDefaults não bate com $LicensePublicKey. Atualize o valor no arquivo (base64 do PEM)."
  }
}
# A validação usa a chave EMBUTIDA no código (src\lib\chavePublicaLicenca.ts) — não configurável no cliente. Ela
# tem de ser a mesma do par em uso, senão o instalador sairia recusando toda licença emitida.
$chaveEmbutida = Join-Path $Backend 'src\lib\chavePublicaLicenca.ts'
if (-not (Test-Path $chaveEmbutida)) { throw "Chave pública embutida não encontrada: $chaveEmbutida" }
$embutida = [regex]::Match((Get-Content $chaveEmbutida -Raw), '-----BEGIN PUBLIC KEY-----[\s\S]*?-----END PUBLIC KEY-----').Value
$doPar = [regex]::Match($licPem, '-----BEGIN PUBLIC KEY-----[\s\S]*?-----END PUBLIC KEY-----').Value
if (($embutida -replace '\s', '') -ne ($doPar -replace '\s', '')) {
  throw "A chave pública embutida em $chaveEmbutida não é a do par em uso ($LicensePublicKey / $GlobalDefaults). Copie o PEM para o arquivo .ts e gere o build de novo."
}

# ---------------------------------------------------------------- dependências
Get-Dependencias
$nodeZip = Join-Path $Deps "node-v$NodeVersion-win-x64.zip"

# ---------------------------------------------------------------- stage limpo
Write-Host "==> Preparando stage"
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Stage, "$Stage\backend", "$Stage\frontend", "$Stage\services", "$Stage\scripts", "$Stage\config" | Out-Null

# ---------------------------------------------------------------- backend
Write-Host "==> Backend (TypeScript -> dist)"
Push-Location $Backend
try {
  # --include=dev: o build (tsc) precisa das devDependencies (ex.: @types/sax) mesmo que a sessão tenha
  # NODE_ENV=production — nesse caso o npm ci as omitiria em silêncio e o tsc falharia. O que vai para o
  # instalador continua só com dependências de produção (npm ci --omit=dev no stage, abaixo).
  Invoke-Checked npm @('ci', '--include=dev')
  # Qualidade ANTES de empacotar: typecheck + toda a suíte de testes. Qualquer falha interrompe o build — não existe
  # opção para pular (o mesmo que o CI do GitHub roda a cada push). Sem .env na máquina de build, um JWT_SECRET
  # aleatório só para o processo dos testes.
  Write-Host "==> Backend: typecheck e testes"
  $jwtAntes = $env:JWT_SECRET
  if (-not (Test-Path '.env') -and -not $env:JWT_SECRET) {
    $b = New-Object byte[] 48; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    $env:JWT_SECRET = [Convert]::ToBase64String($b).TrimEnd('=')
  }
  try {
    Invoke-Checked npm @('run', 'lint')
    Invoke-Checked npm @('test')
  } finally { $env:JWT_SECRET = $jwtAntes }
  Invoke-Checked npm @('run', 'build')
  $pkg = Get-Content package.json -Raw | ConvertFrom-Json

  # Versão instalada, para o /health e o pacote de diagnóstico (src/lib/versao.ts): a do instalador + o commit
  $commit = (& git rev-parse HEAD 2>$null)
  if ($LASTEXITCODE -ne 0 -or -not $commit) { $commit = 'sem-git' }
  elseif (& git status --porcelain 2>$null) { $commit = "$commit-modificado"; Write-Warning 'Backend com alterações não commitadas: o instalador fica marcado como "-modificado".' }
  $versaoJson = [ordered]@{ versao = $Version; commit = "$commit"; geradoEm = (Get-Date).ToString('o') } | ConvertTo-Json -Compress

  # Arquivo de entrada a partir de "scripts.start" (ex.: "node dist/index.js")
  $entry = $null
  if ($pkg.scripts.start -match 'node\s+(\S+)') { $entry = $Matches[1] }
  if (-not $entry) { throw "Não consegui achar o arquivo de entrada em scripts.start do backend (esperado: `"node dist/index.js`")." }
  if (-not (Test-Path 'dist\scripts\onpremise-setup.js')) { throw "dist\scripts\onpremise-setup.js não foi gerado. Copie src\scripts\onpremise-setup.ts para o backend." }

  Copy-Item dist "$Stage\backend\dist" -Recurse
  Copy-Item package.json, package-lock.json "$Stage\backend"
  # UTF-8 SEM BOM: o Set-Content -Encoding UTF8 do PowerShell 5.1 grava BOM, o JSON.parse do backend recusava o
  # arquivo e a versão caía para a do package.json ("1.0.0" na tela)
  [IO.File]::WriteAllText("$Stage\backend\versao.json", $versaoJson, (New-Object Text.UTF8Encoding $false))
  Set-Content -Path "$Stage\backend\entry.txt" -Value $entry -Encoding ASCII
} finally { Pop-Location }

Push-Location "$Stage\backend"
try {
  # "version" do package.json (e do lock) empacotado = a do instalador, para não ficar defasado (o repositório não é
  # alterado; o versao.json continua tendo prioridade em src/lib/versao.ts)
  Invoke-Checked npm @('version', $Version, '--no-git-tag-version', '--allow-same-version')
  # Só dependências de produção; as opcionais (mssql, oracledb) são mantidas
  Invoke-Checked npm @('ci', '--omit=dev')
} finally { Pop-Location }

# ---------------------------------------------------------------- frontend
Write-Host "==> Frontend (VITE_MODO=onpremise)"
Push-Location $Frontend
try {
  # --include=dev: mesmo motivo do backend (o build do front usa devDependencies)
  if (Test-Path 'package-lock.json') { Invoke-Checked npm @('ci', '--include=dev') } else { Invoke-Checked npm @('install', '--include=dev') }
  Write-Host "==> Frontend: typecheck"
  Invoke-Checked npm @('run', 'lint')   # o front ainda não tem testes automatizados; o typecheck é obrigatório
  $env:VITE_MODO    = 'onpremise'
  $env:VITE_API_URL = '/api'      # mesma origem: o backend serve o frontend
  Invoke-Checked npm @('run', 'build')
  Copy-Item "dist\*" "$Stage\frontend" -Recurse
} finally {
  Remove-Item Env:\VITE_MODO, Env:\VITE_API_URL -ErrorAction SilentlyContinue
  Pop-Location
}

# ---------------------------------------------------------------- Node embutido, WinSW, scripts
Write-Host "==> Node $NodeVersion embutido"
$tmpNode = Join-Path $Installer 'node-tmp'
if (Test-Path $tmpNode) { Remove-Item $tmpNode -Recurse -Force }
Expand-Archive -Path $nodeZip -DestinationPath $tmpNode
Move-Item (Join-Path $tmpNode "node-v$NodeVersion-win-x64") "$Stage\node"
Remove-Item $tmpNode -Recurse -Force

Copy-Item (Join-Path $Deps 'WinSW-x64.exe') "$Stage\services\WinSW-x64.exe"
Copy-Item "$Installer\scripts\*.ps1" "$Stage\scripts"
Copy-Item $GlobalDefaults "$Stage\config"   # lido pelo postinstall.ps1 em <app>\config\global-defaults.env

# ---------------------------------------------------------------- compila o instalador
Write-Host "==> Compilando instalador (Inno Setup)"
$isccArgs = @("/DAppVersion=$Version")
if ($SemPostgres) { $isccArgs += '/DSemPostgres' }
$isccArgs += (Join-Path $Installer 'efinanceira.iss')
Invoke-Checked $iscc $isccArgs

Write-Host ""
$suf = if ($SemPostgres) { '-sem-postgres' } else { '' }
Write-Host "Pronto: $Installer\output\efinanceira-onpremise-$Version$suf-setup.exe" -ForegroundColor Green
