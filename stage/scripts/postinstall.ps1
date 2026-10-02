<#
  Executado pelo instalador depois que os arquivos foram copiados.
  Instalação nova : (opcional) instala PostgreSQL, cria banco/usuário, gera segredos, cria as tabelas,
                    cria o Cliente (CNPJ) + administrador, registra e sobe o serviço.
  Atualização     : (config\backend.env já existe) só troca o serviço; o backend aplica as migrations
                    novas sozinho ao iniciar.
  Log: <app>\logs\install.log
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$App       = Split-Path -Parent $PSScriptRoot
$ConfigDir = Join-Path $App 'config'
$LogDir    = Join-Path $App 'logs'
New-Item -ItemType Directory -Force -Path $ConfigDir, $LogDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir 'install.log') -Append | Out-Null

$ParamsFile = Join-Path $ConfigDir 'install-params.json'
$EnvFile    = Join-Path $ConfigDir 'backend.env'
$GlobalsFile = Join-Path $ConfigDir 'global-defaults.env'   # valores fixos de toda instalação (vem do build)
$Node      = Join-Path $App 'node\node.exe'
$BackendDir = Join-Path $App 'backend'
$SvcName    = 'efinanceira-api'
$PgSvc      = 'efinanceira-pg'
$PgPort     = 5433   # fora da 5432 para não colidir com outro PostgreSQL da máquina

function Invoke-Checked {
  param([string]$Exe, [string[]]$ArgList)
  & $Exe @ArgList
  if ($LASTEXITCODE -ne 0) { throw "Falhou: $Exe (código $LASTEXITCODE)" }
}

function New-Secret {   # URL-safe, sem '=' (senhas de banco e segredos)
  param([int]$Bytes = 48)
  $b = New-Object byte[] $Bytes
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  ([Convert]::ToBase64String($b)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-Aes256Key {   # exatamente 32 bytes em base64 padrão (CONNECTION_CIPHER_KEY)
  $b = New-Object byte[] 32
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  [Convert]::ToBase64String($b)
}

function New-HexKey32 {   # exatamente 32 bytes em hexadecimal (ENCRYPTION_KEY do certificado digital)
  $b = New-Object byte[] 32
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  -join ($b | ForEach-Object { $_.ToString('x2') })
}

function Restrict-Acl {
  param([string]$Path)
  & icacls $Path /inheritance:r /grant:r 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null
}

# Segredos do backend.env cifrados via DPAPI (escopo LocalMachine): só esta máquina decifra.
function Protect-Secret {
  param([string]$Value)
  if ([string]::IsNullOrEmpty($Value)) { return $Value }
  $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
  $enc = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
  return 'ENC:' + [Convert]::ToBase64String($enc)
}

function Unprotect-Secret {
  param([string]$Value)
  if ($Value -notlike 'ENC:*') { return $Value }
  $bytes = [Convert]::FromBase64String($Value.Substring(4))
  $plain = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
  return [Text.Encoding]::UTF8.GetString($plain)
}

function Import-EnvFile {
  param([string]$Path)
  Get-Content $Path -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
      [Environment]::SetEnvironmentVariable($Matches[1], (Unprotect-Secret $Matches[2]), 'Process')
    }
  }
}

# Roda um executável capturando stdout+stderr em memória (sem arquivo temporário) e ecoa a saída
# no host, para continuar aparecendo no install.log. No PS 5.1, '2>&1' em comando nativo com
# $ErrorActionPreference='Stop' vira erro terminante na 1ª linha de stderr — por isso o 'Continue' local.
function Invoke-Captured {
  param([string]$Exe, [string[]]$ArgList)
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $out = (& $Exe @ArgList 2>&1 | ForEach-Object { "$_" }) -join "`r`n" }
  finally { $ErrorActionPreference = $prevEap }
  if ($out) { Write-Host $out }
  [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

# Lê config\global-defaults.env (valores globais fixos, públicos) e devolve as linhas KEY=VALUE, na
# ordem do arquivo. Qualquer chave nova no arquivo entra sozinha — nada listado aqui por nome.
function Read-GlobalDefaults {
  param([string]$Path)
  if (-not (Test-Path $Path)) { throw "Arquivo de valores globais não encontrado: $Path" }
  Get-Content $Path -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^\s*(#|$)') { return }
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { "$($Matches[1])=$($Matches[2].TrimEnd())" }
  }
}

function Wait-Port {
  param([int]$Port, [int]$TimeoutSec = 90, [string]$HostName = '127.0.0.1')
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $c = New-Object Net.Sockets.TcpClient
      $c.Connect($HostName, $Port); $c.Close(); return $true
    } catch { Start-Sleep -Seconds 2 }
  }
  return $false
}

try {
  $Fresh = -not (Test-Path $EnvFile)

  # ------------------------------------------------------------------ instalação nova
  if ($Fresh) {
    if (-not (Test-Path $ParamsFile)) { throw "Arquivo de parâmetros do instalador não encontrado." }
    $P = Get-Content $ParamsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Restrict-Acl $ParamsFile   # contém a senha do banco em texto puro até ser apagado no finally

    if ($P.dbMode -eq 'embedded') {
      $pgBin     = Join-Path $App 'pgsql\bin'
      $adminFile = Join-Path $ConfigDir 'pg-admin.txt'

      if (-not (Get-Service $PgSvc -ErrorAction SilentlyContinue)) {
        if (Get-NetTCPConnection -LocalPort $PgPort -State Listen -ErrorAction SilentlyContinue) {
          throw "A porta $PgPort já está em uso; libere-a ou escolha 'Usar um PostgreSQL existente'."
        }
        Write-Host "Instalando PostgreSQL (porta $PgPort)..."
        $super = New-Secret 18
        $pgArgs = @(
          '--mode', 'unattended', '--unattendedmodeui', 'none',
          '--superaccount', 'postgres', '--superpassword', $super,
          '--servicename', $PgSvc, '--serverport', "$PgPort",
          '--prefix', (Join-Path $App 'pgsql'), '--datadir', (Join-Path $App 'pgdata'),
          '--enable-components', 'server,commandlinetools',
          '--disable-components', 'pgAdmin,stackbuilder'
        )
        $proc = Start-Process -FilePath $P.pgInstaller -ArgumentList $pgArgs -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "Instalador do PostgreSQL retornou código $($proc.ExitCode)." }
        Set-Content -Path $adminFile -Value $super -Encoding ASCII
        Restrict-Acl $adminFile
      } else {
        $super = (Get-Content $adminFile -Raw).Trim()
      }
      if ((Get-Service $PgSvc).Status -ne 'Running') { Start-Service $PgSvc }
      if (-not (Wait-Port $PgPort 60)) { throw "PostgreSQL não respondeu na porta $PgPort." }

      $dbType = 'postgres'
      $dbHost = '127.0.0.1'; $dbPort = "$PgPort"; $dbName = 'efinanceira'; $dbUser = 'efinanceira'
      $dbPass = New-Secret 18
      $psql = Join-Path $pgBin 'psql.exe'
      $env:PGPASSWORD = $super
      Invoke-Checked $psql @('-h', '127.0.0.1', '-p', "$PgPort", '-U', 'postgres', '-v', 'ON_ERROR_STOP=1',
        '-c', "CREATE ROLE $dbUser LOGIN PASSWORD '$dbPass';")
      # UTF8 explícito: evita o problema de acentuação por encoding padrão do Windows (WIN1252)
      Invoke-Checked $psql @('-h', '127.0.0.1', '-p', "$PgPort", '-U', 'postgres', '-v', 'ON_ERROR_STOP=1',
        '-c', "CREATE DATABASE $dbName OWNER $dbUser ENCODING 'UTF8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C';")
      Remove-Item Env:\PGPASSWORD
    } else {
      $dbType = if ($P.dbType) { $P.dbType } else { 'postgres' }
      $dbHost = $P.dbHost; $dbPort = $P.dbPort; $dbName = $P.dbName; $dbUser = $P.dbUser; $dbPass = $P.dbPassword
      # "servidor\instancia" do SQL Server: a porta real e resolvida pelo SQL Server Browser
      # (UDP 1434), nao da pra checar com um TcpClient comum como fazemos abaixo (isso exigiria
      # falar o protocolo do Browser). Pula essa pre-checagem nesse caso; dataSource.ts (backend)
      # ja sabe separar host\instancia e deixa o driver (tedious) resolver a porta sozinho — se
      # algo estiver errado, aparece no logs\install.log quando o servico tentar subir.
      if (($dbType -eq 'mssql') -and ($dbHost -match '\\')) {
        Write-Host "Instancia nomeada do SQL Server ($dbHost): pulando pre-checagem de porta (resolvida pelo SQL Server Browser)."
      }
      # Falha cedo e com mensagem clara se o servidor de banco não responde (nome, porta, firewall)
      elseif (-not (Wait-Port ([int]$dbPort) 15 $dbHost)) {
        throw "Não consegui conectar em ${dbHost}:${dbPort} ($dbType). Confira servidor, porta e firewall."
      }
    }

    $globalLines = @(Read-GlobalDefaults $GlobalsFile)   # LICENSE_PUBLIC_KEY_B64, CERT_SERVIDOR_RFB, ...
    $envLines = @(
      'NODE_ENV=production',
      'DEPLOYMENT_TYPE=on-premise',
      "PORT=$($P.httpPort)",
      "FRONTEND_DIR=$(Join-Path $App 'frontend')",
      "DB_TYPE=$dbType",
      "DB_HOST=$(Protect-Secret $dbHost)",
      "DB_PORT=$(Protect-Secret $dbPort)",
      "DB_NAME=$(Protect-Secret $dbName)",
      "DB_USER=$(Protect-Secret $dbUser)",
      "DB_PASSWORD=$(Protect-Secret $dbPass)",
      # Gerados UMA vez. O JWT_SECRET também protege as senhas das bases cadastradas e o
      # CERT_SECRET/CONNECTION_CIPHER_KEY os certificados: se forem perdidos ou trocados, esses dados
      # ficam ilegíveis. Faça backup desta pasta (config). Cifrados com DPAPI LocalMachine: o
      # backup só é decifrável nesta mesma máquina (reinstalação do Windows = segredos perdidos).
      "JWT_SECRET=$(Protect-Secret (New-Secret 48))",
      # ENCRYPTION_KEY: cifra o certificado digital (PFX e senha) — chave própria, separada do JWT_SECRET
      "ENCRYPTION_KEY=$(Protect-Secret (New-HexKey32))",
      "CONNECTION_CIPHER_KEY=$(Protect-Secret (New-Aes256Key))",
      "SETUP_ACTIVATION_CODE=$(Protect-Secret (New-Secret 24))",
      "SUPER_ADMIN_MASTER_CODE=$(Protect-Secret (New-Secret 24))"
    )
    $envLines += $globalLines   # públicos/fixos: texto puro, sem Protect-Secret
    if ($dbType -eq 'oracle') { $envLines += "DB_SERVICE_NAME=$(Protect-Secret $dbName)" }
    if ($dbType -eq 'mssql')  { $envLines += 'DB_ENCRYPT=true'; $envLines += 'DB_TRUST_CERT=true' }   # servidores internos costumam ter certificado próprio
    Set-Content -Path $EnvFile -Value $envLines -Encoding UTF8
    Restrict-Acl $EnvFile
  }
  # ------------------------------------------------------------------ atualização
  else {
    # backend.env já existe e não é recriado; sem isto, um CERT_SERVIDOR_RFB renovado nunca chegaria
    # nas instalações existentes. Atualiza/acrescenta só as chaves de global-defaults.env.
    $current = @(Get-Content $EnvFile -Encoding UTF8)
    $changed = $false
    foreach ($g in @(Read-GlobalDefaults $GlobalsFile)) {
      $key = $g.Substring(0, $g.IndexOf('='))
      $idx = -1
      for ($i = 0; $i -lt $current.Count; $i++) { if ($current[$i] -like "$key=*") { $idx = $i; break } }
      if ($idx -lt 0)                { $current += $g; $changed = $true; Write-Host "global-defaults: $key adicionado ao backend.env." }
      elseif ($current[$idx] -ne $g) { $current[$idx] = $g; $changed = $true; Write-Host "global-defaults: $key atualizado no backend.env." }
    }
    # Instalações anteriores não tinham ENCRYPTION_KEY: gera uma vez. O backend recifra o certificado salvo (que
    # estava com a chave derivada do JWT_SECRET) na primeira vez que o usar.
    if (-not ($current | Where-Object { $_ -like 'ENCRYPTION_KEY=*' })) {
      $current += "ENCRYPTION_KEY=$(Protect-Secret (New-HexKey32))"; $changed = $true
      Write-Host 'ENCRYPTION_KEY gerada e adicionada ao backend.env.'
    }
    if ($changed) { Set-Content -Path $EnvFile -Value $current -Encoding UTF8 }
  }

  Import-EnvFile $EnvFile
  $HttpPort = [int]$env:PORT

  # ------------------------------------------------------------------ tabelas + Cliente + administrador (só instalação nova)
  if ($Fresh) {
    Push-Location $BackendDir
    try {
      $env:CLIENTE_NOME = $P.clienteNome; $env:CLIENTE_CNPJ = $P.clienteCnpj
      $env:ADMIN_NOME   = $P.adminNome;   $env:ADMIN_LOGIN  = $P.adminLogin
      $env:ADMIN_EMAIL  = $P.adminEmail;  $env:ADMIN_SENHA  = $P.adminSenha
      try {
        $setupArgs = @('dist\scripts\onpremise-setup.js')
        $r = Invoke-Captured $Node $setupArgs
        if ($r.ExitCode -ne 0) {
          $firstError = "Falhou: $Node (código $($r.ExitCode))"
          # SQL Server antigo (ex.: 2014): o tedious não negocia TLS pra baixo e cai com "socket hang up",
          # enquanto o .NET SqlClient ("Testar conexão") conecta. Tenta de novo sem criptografia.
          $tlsPattern = 'socket hang up|ESOCKET|self signed certificate|unable to verify the first certificate|ECONNRESET'
          if (($env:DB_TYPE -eq 'mssql') -and ($env:DB_ENCRYPT -ne 'false') -and ($r.Output -match $tlsPattern)) {
            Write-Host 'Falha de conexão TLS detectada com o driver Node — tentando novamente com DB_ENCRYPT=false (compatibilidade com instâncias SQL Server mais antigas).'
            $env:DB_ENCRYPT = 'false'
            $r2 = Invoke-Captured $Node $setupArgs
            if ($r2.ExitCode -ne 0) { throw $firstError }
            $envContent = @(Get-Content $EnvFile -Encoding UTF8)
            if ($envContent -match '^DB_ENCRYPT=') { $envContent = $envContent -replace '^DB_ENCRYPT=.*$', 'DB_ENCRYPT=false' }
            else { $envContent += 'DB_ENCRYPT=false' }
            Set-Content -Path $EnvFile -Value $envContent -Encoding UTF8
            Write-Host 'DB_ENCRYPT=false gravado permanentemente em config\backend.env — necessário para compatibilidade TLS com este servidor SQL Server.'
          } else {
            throw $firstError
          }
        }
      }
      finally { Remove-Item Env:\CLIENTE_NOME, Env:\CLIENTE_CNPJ, Env:\ADMIN_NOME, Env:\ADMIN_LOGIN, Env:\ADMIN_EMAIL, Env:\ADMIN_SENHA -ErrorAction SilentlyContinue }
    } finally { Pop-Location }
  }

  # ------------------------------------------------------------------ serviço do Windows (WinSW)
  $svcDir = Join-Path $App 'services'
  $svcExe = Join-Path $svcDir "$SvcName.exe"

  # Para/remove o serviço antigo ANTES de sobrescrever o executável do WinSW (senão: arquivo em uso)
  if (Get-Service $SvcName -ErrorAction SilentlyContinue) {
    & sc.exe stop $SvcName | Out-Null
    Start-Sleep -Seconds 3
    if (Test-Path $svcExe) { Invoke-Checked $svcExe @('uninstall') }
    else { Invoke-Checked "$env:SystemRoot\System32\sc.exe" @('delete', $SvcName) }
    Start-Sleep -Seconds 2
  }
  Copy-Item (Join-Path $svcDir 'WinSW-x64.exe') $svcExe -Force

  # O serviço roda scripts\run-service.ps1, que decifra config\backend.env só em memória e lança o
  # node.exe. Nenhum segredo vai para o XML do WinSW.
  $esc = { param($s) [Security.SecurityElement]::Escape($s) }
  $psExe     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $runSvc    = Join-Path $App 'scripts\run-service.ps1'
  $svcArgs   = "-NoProfile -ExecutionPolicy Bypass -File `"$runSvc`""
  $dep = ''
  if (Get-Service $PgSvc -ErrorAction SilentlyContinue) { $dep = "  <depend>$PgSvc</depend>" }

  $xml = @"
<service>
  <id>$SvcName</id>
  <name>e-Financeira</name>
  <description>e-Financeira On-Premise (API e interface web)</description>
  <executable>$(& $esc $psExe)</executable>
  <arguments>$(& $esc $svcArgs)</arguments>
  <workingdirectory>$(& $esc $BackendDir)</workingdirectory>
$dep
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <onfailure action="none"/>
  <logpath>$(& $esc $LogDir)</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>8</keepFiles>
  </log>
</service>
"@
  $xmlPath = Join-Path $svcDir "$SvcName.xml"
  Set-Content -Path $xmlPath -Value $xml -Encoding UTF8
  Restrict-Acl $xmlPath   # sem segredos, mas define o que roda como SYSTEM

  Invoke-Checked $svcExe @('install')
  Invoke-Checked $svcExe @('start')

  # ------------------------------------------------------------------ firewall e atalho
  if ($Fresh -and $P.firewall) {
    Get-NetFirewallRule -DisplayName 'e-Financeira' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'e-Financeira' -Direction Inbound -Protocol TCP -LocalPort $HttpPort -Action Allow | Out-Null
  }
  Set-Content -Path (Join-Path $App 'e-Financeira.url') -Encoding ASCII -Value @(
    '[InternetShortcut]', "URL=http://localhost:$HttpPort")

  if (-not (Wait-Port $HttpPort 90)) {
    throw "O serviço foi iniciado, mas a porta $HttpPort não respondeu. Veja os logs em $LogDir."
  }
  Write-Host "e-Financeira no ar: http://localhost:$HttpPort"
  exit 0
}
catch {
  Write-Host "ERRO: $($_ | Out-String)"
  exit 1
}
finally {
  if (Test-Path $ParamsFile) { Remove-Item $ParamsFile -Force }   # contém senhas
  Stop-Transcript | Out-Null
}
