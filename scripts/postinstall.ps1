<#
  Executado pelo instalador depois que os arquivos foram copiados.
  Instalação nova : (opcional) instala PostgreSQL, cria banco/usuário, gera segredos, cria as tabelas,
                    cria o Cliente (CNPJ) + administrador, registra e sobe o serviço.
  Atualização     : (config\backend.env já existe) atualiza o serviço existente no lugar (sem recriá-lo) e
                    reaplica a configuração de boot; o backend aplica as migrations novas sozinho ao iniciar.
  Log: <app>\logs\install.log
  Falha: <app>\logs\install-erro.txt — linha útil do erro + etapa, mostrada na tela de falha do instalador.
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

# ------------------------------------------------------------------ certificados de criptografia da RFB
# Os certificados públicos da RFB para cifrar os lotes (Produção e Produção Restrita) vêm no pacote do backend
# (backend\dist\recursos\rfb) e ficam em config\rfb, de onde o sistema os lê (RFB_CERTS_DIR, ver run-service.ps1).
# O Administrador renova pela tela (Configurações > Certificados da RFB) ou trocando o arquivo, sem reinstalar.
# Na atualização, o arquivo da pasta só é trocado pelo do pacote se o do pacote vencer DEPOIS (não desfaz uma
# renovação mais nova feita pelo Administrador); o anterior fica como .anterior.
function Install-CertificadosRfb {
  $origem  = Join-Path $App 'backend\dist\recursos\rfb'
  $destino = Join-Path $ConfigDir 'rfb'
  New-Item -ItemType Directory -Force -Path $destino | Out-Null
  foreach ($arq in @(Get-ChildItem -Path $origem -Filter '*.cer' -ErrorAction SilentlyContinue)) {
    $alvo = Join-Path $destino $arq.Name
    $novo = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $arq.FullName
    if (-not (Test-Path $alvo)) {
      Copy-Item $arq.FullName $alvo
      Write-Host "Certificado RFB $($arq.Name) instalado (vence em $($novo.NotAfter.ToString('dd/MM/yyyy')))."
      continue
    }
    $atual = $null
    try { $atual = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $alvo } catch { }
    if (-not $atual -or $novo.NotAfter -gt $atual.NotAfter) {
      Copy-Item $alvo "$alvo.anterior" -Force
      Copy-Item $arq.FullName $alvo -Force
      Write-Host "Certificado RFB $($arq.Name) atualizado pelo do pacote (vence em $($novo.NotAfter.ToString('dd/MM/yyyy')))."
    } else {
      Write-Host "Certificado RFB $($arq.Name) mantido (o da pasta vence em $($atual.NotAfter.ToString('dd/MM/yyyy')), não antes do do pacote)."
    }
  }
}

# ------------------------------------------------------------------ resumo do erro para a tela do instalador
# Antes a falha só dizia "a configuração final falhou (código 1), veja o log". Agora o catch grava em
# logs\install-erro.txt a linha útil do erro (da saída do último comando externo que falhou — o setup em Node, por
# exemplo — ou da exceção) e a etapa em andamento; o efinanceira.iss mostra isso. O arquivo de uma execução anterior é
# apagado aqui, para nunca exibir um erro velho.
$ErroFile = Join-Path $LogDir 'install-erro.txt'
if (Test-Path $ErroFile) { Remove-Item $ErroFile -Force }
$script:Etapa = 'Preparação'
$script:SaidaDaFalha = $null   # saída do último Invoke-Captured com código <> 0 (zerada quando um comando dá certo)

function Get-LinhaUtilDeErro {
  param([string]$Saida, [string]$Mensagem)
  $linhas = @(("$Saida" -split "`r?`n") | ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and $_ -notmatch '^at\s' -and $_ -notmatch '^[\]\[{}(),]+$' })
  # 1º a migration que falhou (TypeORM); 2º a linha "XxxError: ..."; 3º qualquer linha com cara de erro; 4º a última
  $linha = $linhas | Where-Object { $_ -match 'Migration\s.+\sfailed' } | Select-Object -Last 1
  if (-not $linha) { $linha = $linhas | Where-Object { $_ -match '^[A-Za-z]*Error:\s' } | Select-Object -Last 1 }
  if (-not $linha) { $linha = $linhas | Where-Object { $_ -match '(?i)(error|erro|falh|failed|fatal|exception|inv[aá]lid)' } | Select-Object -Last 1 }
  if (-not $linha) { $linha = $linhas | Select-Object -Last 1 }
  if (-not $linha) { $linha = "$Mensagem".Trim() }
  # Nunca leva senha para a tela: senha/password/pwd/secret = valor
  $linha = $linha -replace '(?i)\b(password|senha|pwd|secret)(\s*["'']?\s*[:=]\s*)("[^"]*"|''[^'']*''|[^\s;,]+)', '$1$2***'
  if ($linha.Length -gt 300) { $linha = $linha.Substring(0, 297) + '...' }
  return $linha
}

function Write-ErroInstalacao {
  param([string]$Linha)
  # UTF-8 com BOM (Out-File do PS 5.1): o Utf8Decode do efinanceira.iss pula o BOM
  @($Linha, "Etapa: $script:Etapa") | Out-File -FilePath $ErroFile -Encoding utf8
}

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
  $codigo = $LASTEXITCODE
  if ($out) { Write-Host $out }
  # Para o resumo do erro (install-erro.txt): só a saída do comando que falhou; um que dá certo limpa a anterior
  $script:SaidaDaFalha = if ($codigo -ne 0) { $out } else { $null }
  [pscustomobject]@{ ExitCode = $codigo; Output = $out }
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

# Atualização: o backend.env já existe e não é recriado; sem isto, um valor global novo ou renovado (ex.:
# SUPORTE_CONTATO) nunca chegaria nas instalações existentes. Acrescenta/atualiza só as chaves de global-defaults.env;
# as demais linhas (segredos cifrados, DB_*) ficam como estão. Teste: tools\testar-postinstall-config.ps1.
function Merge-GlobalDefaults {
  param([string[]]$Atual, [string[]]$Globais)
  $linhas = @($Atual | Where-Object { $null -ne $_ })
  $mudou = $false
  foreach ($g in $Globais) {
    $key = $g.Substring(0, $g.IndexOf('='))
    $idx = -1
    for ($i = 0; $i -lt $linhas.Count; $i++) { if ($linhas[$i] -like "$key=*") { $idx = $i; break } }
    if ($idx -lt 0)               { $linhas += $g; $mudou = $true; Write-Host "global-defaults: $key adicionado ao backend.env." }
    elseif ($linhas[$idx] -ne $g) { $linhas[$idx] = $g; $mudou = $true; Write-Host "global-defaults: $key atualizado no backend.env." }
  }
  return @{ Linhas = $linhas; Mudou = $mudou }
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

# ------------------------------------------------------------------ robustez do serviço no boot
# Sem isto o serviço subia em Automático puro, antes do banco local (SQL Server e SQL Browser vêm em
# Automático-Atraso), falhava 3 vezes e o SCM desistia. Aplicado via sc.exe nos dois fluxos (instalação
# nova e atualização): o WinSW 2.x só grava essas opções no "install" e não tem "refresh".
$SvcResetSec    = 86400
$SvcFailActions = 'restart/30000/restart/60000/restart/120000'   # a última ação se repete até o reset

function Test-HostLocal {
  param([string]$HostName)
  $h = $HostName.Trim().ToLowerInvariant()
  if ($h -in @('localhost', '.', '(local)', '::1') -or $h -like '127.*') { return $true }
  $nomes = @($env:COMPUTERNAME.ToLowerInvariant())
  try { $nomes += [Net.Dns]::GetHostEntry('').HostName.ToLowerInvariant() } catch {}
  if ($h -in $nomes) { return $true }
  $ips = @(Get-NetIPAddress -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress.Split('%')[0].ToLowerInvariant() })
  return ($h -in $ips)
}

# Serviço (processo próprio) dono da porta TCP em escuta, subindo até 3 níveis na árvore de processos
# (PostgreSQL: quem escuta é o postgres.exe, filho do pg_ctl.exe que é o processo do serviço).
function Get-ServicoDaPorta {
  param([int]$Port)
  $conns = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
  if (-not $conns) { return $null }
  $porPid = @{}
  Get-CimInstance Win32_Service -Filter "ProcessId <> 0 AND ServiceType = 'Own Process'" |
    ForEach-Object { $porPid[[int]$_.ProcessId] = $_ }
  foreach ($c in $conns) {
    $procId = [int]$c.OwningProcess
    for ($i = 0; $i -lt 3 -and $procId -gt 4; $i++) {
      if ($porPid.ContainsKey($procId)) { return $porPid[$procId] }
      $p = Get-CimInstance Win32_Process -Filter "ProcessId = $procId" -ErrorAction SilentlyContinue
      if (-not $p) { break }
      $procId = [int]$p.ParentProcessId
    }
  }
  return $null
}

# PostgreSQL parado (porta sem dono): procura entre os serviços pg_ctl o que usa essa porta no postgresql.conf.
function Get-ServicoPostgresPorConfig {
  param([int]$Port)
  $achados = @()
  foreach ($s in @(Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'pg_ctl(\.exe)?' })) {
    $porta = 5432
    if ($s.PathName -match '-D\s+"([^"]+)"|-D\s+(\S+)') {
      $conf = Join-Path ($(if ($Matches[1]) { $Matches[1] } else { $Matches[2] })) 'postgresql.conf'
      if (Test-Path $conf) {
        $linha = Get-Content $conf | Where-Object { $_ -match '^\s*port\s*=\s*(\d+)' } | Select-Object -Last 1
        if ($linha -match '^\s*port\s*=\s*(\d+)') { $porta = [int]$Matches[1] }
      }
    }
    if ($porta -eq $Port) { $achados += $s }
  }
  if ($achados.Count -eq 1) { return $achados[0] }
  return $null
}

# Serviços do Windows dos quais o efinanceira-api deve depender: só quando o banco está NESTA máquina.
# Remoto, não encontrado ou desabilitado = nenhuma dependência (o motivo vai para este log).
function Get-DependenciasBanco {
  param([string]$DbType, [string]$DbHost, [string]$DbPort, [string]$DbName)
  $candidatos = @()   # pares nome/motivo
  if (-not $DbHost) { Write-Host 'Dependência do banco: DB_HOST vazio — nenhuma dependência definida.'; return @() }

  $servidor = ($DbHost -split ',')[0].Trim()   # "servidor,porta" (sintaxe do SQL Server)
  $instancia = ''
  if (($DbType -eq 'mssql') -and ($servidor -match '^([^\\]+)\\(.+)$')) { $servidor = $Matches[1]; $instancia = $Matches[2] }
  $porta = 0; [void][int]::TryParse("$DbPort", [ref]$porta)

  if (-not (Test-HostLocal $servidor)) {
    Write-Host "Dependência do banco: servidor '$servidor' é remoto — nenhuma dependência de serviço definida (só vale para banco nesta máquina)."
    return @()
  }

  switch ($DbType) {
    'mssql' {
      if ($instancia) {
        $nome = if ($instancia -ieq 'MSSQLSERVER') { 'MSSQLSERVER' } else { 'MSSQL$' + $instancia }
        $candidatos += , @($nome, "instância '$instancia' do SQL Server local")
        if ($instancia -ine 'MSSQLSERVER') {
          # Instância nomeada sem porta fixa: o driver descobre a porta pelo SQL Browser (UDP 1434)
          $candidatos += , @('SQLBrowser', "resolve a porta da instância nomeada '$instancia'")
        }
      } else {
        if ($porta -le 0) { $porta = 1433 }
        $s = Get-ServicoDaPorta $porta
        if ($s -and $s.Name -like 'MSSQL*') { $candidatos += , @($s.Name, "dono da porta $porta") }
        else { $candidatos += , @('MSSQLSERVER', "instância padrão do SQL Server (porta $porta sem dono identificado)") }
      }
    }
    'postgres' {
      if ($porta -le 0) { $porta = 5432 }
      $s = Get-ServicoDaPorta $porta
      if (-not $s) { $s = Get-ServicoPostgresPorConfig $porta }
      if ($s) { $candidatos += , @($s.Name, "PostgreSQL local na porta $porta") }
      else { Write-Host "Dependência do banco: nenhum serviço do PostgreSQL encontrado para a porta $porta — dependência não definida." }
    }
    'oracle' {
      if ($porta -le 0) { $porta = 1521 }
      $s = Get-ServicoDaPorta $porta
      if ($s) { $candidatos += , @($s.Name, "listener do Oracle na porta $porta") }
      else { Write-Host "Dependência do banco: nenhum serviço escutando na porta $porta (listener do Oracle) — listener fora da dependência." }
      $inst = @(Get-CimInstance Win32_Service | Where-Object { $_.Name -like 'OracleService*' })
      if ($inst.Count -gt 1 -and $DbName) {
        # Mais de uma instância: aceita só se o service name começar pelo SID (ex.: ORCL -> ORCLPDB1)
        $inst = @($inst | Where-Object { $DbName -like ($_.Name.Substring('OracleService'.Length) + '*') })
      }
      if ($inst.Count -eq 1) { $candidatos += , @($inst[0].Name, 'instância do Oracle local') }
      elseif ($inst.Count -eq 0) { Write-Host 'Dependência do banco: nenhum serviço OracleService* correspondente — instância fora da dependência.' }
      else { Write-Host "Dependência do banco: mais de uma instância Oracle possível ($(($inst | ForEach-Object Name) -join ', ')) — instância fora da dependência." }
    }
  }

  $deps = @()
  foreach ($c in $candidatos) {
    $svc = Get-CimInstance Win32_Service -Filter "Name = '$($c[0])'" -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Host "Dependência do banco: serviço '$($c[0])' ($($c[1])) não existe nesta máquina — não definida." }
    elseif ($svc.StartMode -eq 'Disabled') { Write-Host "Dependência do banco: serviço '$($c[0])' ($($c[1])) está Desabilitado — não definida (impediria a API de subir)." }
    else { Write-Host "Dependência do banco: '$($c[0])' ($($c[1]))."; $deps += $svc.Name }
  }
  return $deps
}

# Dependências lidas/gravadas direto na API do SCM (QueryServiceConfigW / ChangeServiceConfigW), com a lista
# como array — sem montar linha de comando ("sc config depend=" digitado no cmd gravou aspas literais e o
# serviço caiu no erro 1075). Gravar só o DependOnService do registro não serve: o SCM só relê no boot.
# Grupos de ordem de carga vêm com o prefixo '+' (SC_GROUP_IDENTIFIER), como no sc.exe.
if (-not ('EfinSvcDeps' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class EfinSvcDeps {
  const uint SC_MANAGER_CONNECT = 0x1, SERVICE_QUERY_CONFIG = 0x1, SERVICE_CHANGE_CONFIG = 0x2, SERVICE_NO_CHANGE = 0xFFFFFFFF;

  [DllImport("advapi32.dll", EntryPoint = "OpenSCManagerW", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern IntPtr OpenSCManager(string machine, string database, uint access);
  [DllImport("advapi32.dll", EntryPoint = "OpenServiceW", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern IntPtr OpenService(IntPtr scm, string name, uint access);
  [DllImport("advapi32.dll", EntryPoint = "ChangeServiceConfigW", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool ChangeServiceConfig(IntPtr svc, uint type, uint start, uint errorControl, string binPath,
    string loadOrderGroup, IntPtr tagId, string dependencies, string startName, string password, string displayName);
  [DllImport("advapi32.dll", EntryPoint = "QueryServiceConfigW", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool QueryServiceConfig(IntPtr svc, IntPtr buffer, int size, out int needed);
  [DllImport("advapi32.dll", SetLastError = true)]
  static extern bool CloseServiceHandle(IntPtr h);

  [StructLayout(LayoutKind.Sequential)]
  struct QUERY_SERVICE_CONFIG {
    public uint ServiceType, StartType, ErrorControl;
    public IntPtr BinaryPathName, LoadOrderGroup;
    public uint TagId;
    public IntPtr Dependencies, ServiceStartName, DisplayName;
  }

  static IntPtr Abrir(string name, uint access, out IntPtr scm) {
    scm = OpenSCManager(null, null, SC_MANAGER_CONNECT);
    if (scm == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenSCManager");
    IntPtr svc = OpenService(scm, name, access);
    if (svc == IntPtr.Zero) { int e = Marshal.GetLastWin32Error(); CloseServiceHandle(scm); throw new Win32Exception(e, "OpenService " + name); }
    return svc;
  }

  // Dependências exatamente como o SCM as tem agora (é o que o "sc qc" mostra)
  public static string[] Get(string name) {
    IntPtr scm, svc = Abrir(name, SERVICE_QUERY_CONFIG, out scm);
    IntPtr buf = IntPtr.Zero;
    try {
      int needed;
      QueryServiceConfig(svc, IntPtr.Zero, 0, out needed);
      buf = Marshal.AllocHGlobal(needed);
      if (!QueryServiceConfig(svc, buf, needed, out needed)) throw new Win32Exception(Marshal.GetLastWin32Error(), "QueryServiceConfig");
      var cfg = (QUERY_SERVICE_CONFIG)Marshal.PtrToStructure(buf, typeof(QUERY_SERVICE_CONFIG));
      var lista = new List<string>();
      IntPtr p = cfg.Dependencies;
      while (p != IntPtr.Zero) {   // REG_MULTI_SZ: strings terminadas em \0, lista terminada em \0\0
        string s = Marshal.PtrToStringUni(p);
        if (string.IsNullOrEmpty(s)) break;
        lista.Add(s);
        p = new IntPtr(p.ToInt64() + (s.Length + 1) * 2);
      }
      return lista.ToArray();
    } finally {
      if (buf != IntPtr.Zero) Marshal.FreeHGlobal(buf);
      CloseServiceHandle(svc); CloseServiceHandle(scm);
    }
  }

  // Substitui a lista inteira; vazia = sem dependências. Nada além das dependências é alterado.
  public static void Set(string name, string[] deps) {
    foreach (string d in deps)
      if (string.IsNullOrEmpty(d) || d.IndexOf('\0') >= 0 || d.IndexOf('/') >= 0) throw new ArgumentException("Nome de dependência inválido: <" + d + ">");
    string multi = deps.Length == 0 ? "" : string.Join("\0", deps) + "\0";   // o marshaller põe o \0 final
    IntPtr scm, svc = Abrir(name, SERVICE_CHANGE_CONFIG, out scm);
    try {
      if (!ChangeServiceConfig(svc, SERVICE_NO_CHANGE, SERVICE_NO_CHANGE, SERVICE_NO_CHANGE, null, null, IntPtr.Zero, multi, null, null, null))
        throw new Win32Exception(Marshal.GetLastWin32Error(), "ChangeServiceConfig");
    } finally { CloseServiceHandle(svc); CloseServiceHandle(scm); }
  }
}
'@
}

# Uma dependência só é aceita se existir com o nome EXATO (Get-Service aceita curinga e nome de exibição — por isso
# a comparação) e não estiver Desabilitada (o serviço não subiria). Grupo ('+Nome'): precisa estar no ServiceGroupOrder.
function Test-DependenciaValida {
  param([string]$Nome)
  if ($Nome -like '+*') {
    $grupos = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ServiceGroupOrder' -ErrorAction SilentlyContinue).List
    if ($grupos -contains $Nome.Substring(1)) { return '' }
    return 'grupo de serviços inexistente'
  }
  $s = $null
  try { $s = Get-Service -Name $Nome -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $Nome } } catch {}   # ex.: '[' = curinga inválido
  if (-not $s) { return 'serviço inexistente' }
  if ($s.StartType -eq 'Disabled') { return 'serviço Desabilitado' }
  return ''
}

# Grava (atuais válidas + banco), confere no SCM e no "sc qc"; se algo não bater, remove TODAS as dependências:
# sem dependência o serviço sempre consegue iniciar (o restart do SCM cobre o banco atrasado).
function Set-DependenciasServico {
  param([string]$Name, [string[]]$DepsBanco)
  $atuais = @([EfinSvcDeps]::Get($Name))
  $desejadas = @()
  foreach ($d in @($atuais) + @($DepsBanco)) {
    if ([string]::IsNullOrWhiteSpace($d)) { continue }
    if ($desejadas | Where-Object { $_ -ieq $d }) { continue }
    $motivo = Test-DependenciaValida $d
    if ($motivo) { Write-Host "Dependência <$d> removida: $motivo (com ela o serviço não inicia — erro 1075/1068)." }
    else { $desejadas += $d }
  }
  $antes = if ($atuais) { ($atuais | ForEach-Object { "<$_>" }) -join ' ' } else { 'nenhuma' }
  $depois = if ($desejadas) { ($desejadas | ForEach-Object { "<$_>" }) -join ' ' } else { 'nenhuma' }
  if (($atuais -join "`n") -ceq ($desejadas -join "`n")) { Write-Host "Dependências do serviço mantidas: $depois" }
  else {
    Write-Host "Dependências do serviço: $depois (antes: $antes)"
    [EfinSvcDeps]::Set($Name, [string[]]$desejadas)
  }

  # Conferência: o que o SCM devolve tem de ser exatamente o gravado, cada nome válido e presente no "sc qc"
  $gravadas = @([EfinSvcDeps]::Get($Name))
  $qc = (& (Join-Path $env:SystemRoot 'System32\sc.exe') qc $Name | Out-String)
  $falha = ''
  if (($gravadas -join "`n") -cne ($desejadas -join "`n")) { $falha = "SCM devolveu <$($gravadas -join '> <')>, esperado <$($desejadas -join '> <')>" }
  foreach ($g in $gravadas) {
    $m = Test-DependenciaValida $g
    if ($m) { $falha = "<$g>: $m" }
    elseif ($qc -notmatch [regex]::Escape($g.TrimStart('+'))) { $falha = "<$g> não aparece no sc qc" }
  }
  if ($falha) {
    Write-Host "Conferência das dependências falhou ($falha): removendo todas as dependências para o serviço continuar iniciando."
    [EfinSvcDeps]::Set($Name, [string[]]@())
    if (@([EfinSvcDeps]::Get($Name)).Count -ne 0) { throw "Não consegui limpar as dependências do serviço $Name." }
  } else {
    Write-Host "Conferência das dependências OK: $depois"
  }
}

# Automático (Atraso), ações de falha e dependências — no serviço atual, sem recriá-lo.
function Set-ServicoRobusto {
  param([string]$Name, [string[]]$DepsBanco)
  $sc = Join-Path $env:SystemRoot 'System32\sc.exe'
  Invoke-Checked $sc @('config', $Name, 'start=', 'delayed-auto')
  Invoke-Checked $sc @('failure', $Name, 'reset=', "$SvcResetSec", 'actions=', $SvcFailActions)
  Invoke-Checked $sc @('failureflag', $Name, '1')
  Set-DependenciasServico $Name $DepsBanco
}

function Write-ServicoConfig {
  param([string]$Name)
  $sc = Join-Path $env:SystemRoot 'System32\sc.exe'
  Write-Host "---- validação do serviço $Name ----"
  foreach ($q in 'qc', 'qfailure', 'qfailureflag') { [void](Invoke-Captured $sc @($q, $Name)) }
  Write-Host '------------------------------------'
}

try {
  $Fresh = -not (Test-Path $EnvFile)

  # ------------------------------------------------------------------ instalação nova
  if ($Fresh) {
    if (-not (Test-Path $ParamsFile)) { throw "Arquivo de parâmetros do instalador não encontrado." }
    $P = Get-Content $ParamsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Restrict-Acl $ParamsFile   # contém a senha do banco em texto puro até ser apagado no finally

    if ($P.dbMode -eq 'embedded') {
      $script:Etapa = 'Instalação do PostgreSQL embutido e criação do banco'
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
      $script:Etapa = 'Conexão com o banco de dados'
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

    $script:Etapa = 'Gravação da configuração (config\backend.env)'
    $globalLines = @(Read-GlobalDefaults $GlobalsFile)   # LICENSE_PUBLIC_KEY_B64, ...
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
    $script:Etapa = 'Atualização da configuração (config\backend.env)'
    # backend.env já existe e não é recriado; sem isto, um valor global renovado nunca chegaria
    # nas instalações existentes. Atualiza/acrescenta só as chaves de global-defaults.env.
    $mescla = Merge-GlobalDefaults @(Get-Content $EnvFile -Encoding UTF8) @(Read-GlobalDefaults $GlobalsFile)
    $current = $mescla.Linhas
    $changed = $mescla.Mudou
    # Instalações anteriores não tinham ENCRYPTION_KEY: gera uma vez. O backend recifra o certificado salvo (que
    # estava com a chave derivada do JWT_SECRET) na primeira vez que o usar.
    if (-not ($current | Where-Object { $_ -like 'ENCRYPTION_KEY=*' })) {
      $current += "ENCRYPTION_KEY=$(Protect-Secret (New-HexKey32))"; $changed = $true
      Write-Host 'ENCRYPTION_KEY gerada e adicionada ao backend.env.'
    }
    # CERT_SERVIDOR_RFB (um certificado só, o da Produção Restrita, usado também em Produção) foi substituído pelos
    # arquivos de config\rfb (um por ambiente): sai do backend.env para não confundir quem o ler
    $semCertAntigo = @($current | Where-Object { $_ -notlike 'CERT_SERVIDOR_RFB=*' })
    if ($semCertAntigo.Count -ne $current.Count) {
      $current = $semCertAntigo; $changed = $true
      Write-Host 'CERT_SERVIDOR_RFB removido do backend.env (agora: config\rfb, um certificado por ambiente).'
    }
    if ($changed) { Set-Content -Path $EnvFile -Value $current -Encoding UTF8 }
  }

  # Certificados de criptografia de lotes da RFB (um por ambiente) em config\rfb — renováveis sem reinstalar
  $script:Etapa = 'Certificados de criptografia da RFB (config\rfb)'
  Install-CertificadosRfb

  Import-EnvFile $EnvFile
  $HttpPort = [int]$env:PORT

  # ------------------------------------------------------------------ tabelas + Cliente + administrador (só instalação nova)
  if ($Fresh) {
    $script:Etapa = 'Criação das tabelas, da instituição e do administrador'
    Push-Location $BackendDir
    try {
      $env:CLIENTE_NOME = $P.clienteNome; $env:CLIENTE_CNPJ = $P.clienteCnpj
      $env:ADMIN_NOME   = $P.adminNome;   $env:ADMIN_LOGIN  = $P.adminLogin
      $env:ADMIN_EMAIL  = $P.adminEmail;  $env:ADMIN_SENHA  = $P.adminSenha
      # Banco que já tinha o e-Financeira: o setup grava aqui o aviso (administrador NÃO criado), que o instalador
      # mostra no fim (item 1 das pendências 1.2.28)
      $env:SETUP_AVISO_ARQUIVO = Join-Path $LogDir 'install-aviso.txt'
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
      finally { Remove-Item Env:\CLIENTE_NOME, Env:\CLIENTE_CNPJ, Env:\ADMIN_NOME, Env:\ADMIN_LOGIN, Env:\ADMIN_EMAIL, Env:\ADMIN_SENHA, Env:\SETUP_AVISO_ARQUIVO -ErrorAction SilentlyContinue }
    } finally { Pop-Location }
  }

  # ------------------------------------------------------------------ serviço do Windows (WinSW)
  $script:Etapa = 'Registro do serviço do Windows'
  $svcDir = Join-Path $App 'services'
  $svcExe = Join-Path $svcDir "$SvcName.exe"

  # Serviço já existente apontando para o nosso WinSW: atualiza no lugar (para, troca exe/XML, reaplica a
  # configuração de boot) — sem recriar. Só recria se estiver registrado com outro executável.
  $svcAtual = Get-CimInstance Win32_Service -Filter "Name = '$SvcName'" -ErrorAction SilentlyContinue
  $noLugar = $false
  if ($svcAtual) {
    $binAtual = $svcAtual.PathName.Trim().Trim('"')
    $noLugar = ($binAtual -ieq $svcExe)
    # Para ANTES de sobrescrever o executável do WinSW (senão: arquivo em uso)
    & sc.exe stop $SvcName | Out-Null
    try { (Get-Service $SvcName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30)) }
    catch { throw "O serviço $SvcName não parou em 30 segundos." }
    if ($noLugar) {
      Write-Host "Serviço $SvcName existente: atualizando no lugar, sem recriar."
    } else {
      Write-Host "Serviço $SvcName registrado com outro executável ($binAtual): recriando."
      if (Test-Path $svcExe) { Invoke-Checked $svcExe @('uninstall') }
      else { Invoke-Checked "$env:SystemRoot\System32\sc.exe" @('delete', $SvcName) }
      Start-Sleep -Seconds 2
    }
  }
  Copy-Item (Join-Path $svcDir 'WinSW-x64.exe') $svcExe -Force

  # Banco nesta máquina? Vale para os dois fluxos: DB_* vêm do backend.env já decifrado acima
  $dbName = if ($env:DB_SERVICE_NAME) { $env:DB_SERVICE_NAME } else { $env:DB_NAME }
  $depsBanco = @(Get-DependenciasBanco $env:DB_TYPE $env:DB_HOST $env:DB_PORT $dbName)

  # O serviço roda scripts\run-service.ps1, que decifra config\backend.env só em memória e lança o
  # node.exe. Nenhum segredo vai para o XML do WinSW.
  $esc = { param($s) [Security.SecurityElement]::Escape($s) }
  $psExe     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $runSvc    = Join-Path $App 'scripts\run-service.ps1'
  $svcArgs   = "-NoProfile -ExecutionPolicy Bypass -File `"$runSvc`""
  # Mesmas dependências no XML, para um "install" manual do WinSW sair igual ao que o sc.exe aplica
  $dep = ($depsBanco | ForEach-Object { "  <depend>$(& $esc $_)</depend>" }) -join "`r`n"

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
  <delayedAutoStart>true</delayedAutoStart>
  <onfailure action="restart" delay="30 sec"/>
  <onfailure action="restart" delay="60 sec"/>
  <onfailure action="restart" delay="120 sec"/>
  <resetfailure>1 day</resetfailure>
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

  if (-not $noLugar) { Invoke-Checked $svcExe @('install') }
  Set-ServicoRobusto $SvcName $depsBanco
  Write-ServicoConfig $SvcName   # antes do start: fica no log mesmo se o serviço não subir
  $script:Etapa = 'Início do serviço'
  Invoke-Checked $svcExe @('start')

  # ------------------------------------------------------------------ firewall e atalho
  if ($Fresh -and $P.firewall) {
    Get-NetFirewallRule -DisplayName 'e-Financeira' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'e-Financeira' -Direction Inbound -Protocol TCP -LocalPort $HttpPort -Action Allow | Out-Null
  }
  Set-Content -Path (Join-Path $App 'e-Financeira.url') -Encoding ASCII -Value @(
    '[InternetShortcut]', "URL=http://localhost:$HttpPort")

  $script:Etapa = "Aguardando o e-Financeira responder na porta $HttpPort"
  if (-not (Wait-Port $HttpPort 90)) {
    throw "O serviço foi iniciado, mas a porta $HttpPort não respondeu. Veja os logs em $LogDir."
  }
  Write-Host "e-Financeira no ar: http://localhost:$HttpPort"
  exit 0
}
catch {
  $falha = $_
  Write-Host "ERRO: $($falha | Out-String)"
  # Resumo para a tela de falha do instalador; se até isto falhar, o instalador mostra a mensagem genérica
  try { Write-ErroInstalacao (Get-LinhaUtilDeErro $script:SaidaDaFalha $falha.Exception.Message) } catch { Write-Host "Não consegui gravar $ErroFile : $_" }
  exit 1
}
finally {
  if (Test-Path $ParamsFile) { Remove-Item $ParamsFile -Force }   # contém senhas
  Stop-Transcript | Out-Null
}
