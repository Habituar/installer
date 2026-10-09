<#
  Redefine a senha de um administrador do e-Financeira, no próprio servidor — para quando o único administrador
  esqueceu a senha (no on-premise não há "esqueci a senha" por e-mail). Atalho no menu Iniciar: "Redefinir senha do
  administrador". Execute como Administrador do Windows:
      powershell -ExecutionPolicy Bypass -File "<app>\scripts\redefinir-senha-admin.ps1"

  1. Lista os administradores (login, e-mail, situação).
  2. Pergunta o login e pede confirmação explícita (digitar SIM).
  3. Gera uma senha temporária forte, obriga a troca no próximo login, desbloqueia (e reativa, se estiver inativo) o
     usuário, encerra as sessões abertas dele e registra na Auditoria (usuário "servidor:<usuário do Windows>").
  4. Mostra a senha temporária SÓ nesta janela. Ela não é gravada em log, arquivo nem Auditoria.

  Para suporte (sem perguntas): -Login <login> -Confirmar
#>
param([string]$Login = '', [switch]$Confirmar)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$App        = Split-Path -Parent $PSScriptRoot
$EnvFile    = Join-Path $App 'config\backend.env'
$Node       = Join-Path $App 'node\node.exe'
$BackendDir = Join-Path $App 'backend'
$LogFile    = Join-Path $App 'logs\redefinir-senha-admin.log'

# Ambiente do backend: segredos DPAPI decifrados só na memória deste processo (como o run-service.ps1)
function Import-AmbienteBackend {
  param([string]$Arquivo)
  if (-not (Test-Path $Arquivo)) { throw "Configuração não encontrada: $Arquivo" }
  Get-Content $Arquivo -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
      $valor = $Matches[2]
      if ($valor -like 'ENC:*') {
        $valor = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect(
          [Convert]::FromBase64String($valor.Substring(4)), $null, [Security.Cryptography.DataProtectionScope]::LocalMachine))
      }
      [Environment]::SetEnvironmentVariable($Matches[1], $valor, 'Process')
    }
  }
}

# Roda dist\scripts\redefinirSenhaAdmin.js; devolve o código de saída e as linhas da saída (stdout + stderr)
function Invoke-ScriptRedefinicao {
  param([string]$NodeExe, [string]$Backend, [string[]]$ArgList)
  Push-Location $Backend
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $linhas = @(& $NodeExe 'dist\scripts\redefinirSenhaAdmin.js' @ArgList 2>&1 | ForEach-Object { "$_" }) }
  finally { $ErrorActionPreference = $eap; Pop-Location }
  [pscustomobject]@{ Codigo = $LASTEXITCODE; Linhas = $linhas }
}

# A senha temporária vem numa linha "SENHA_TEMPORARIA=..."; o resto da saída pode ir para a tela e para o log
function Get-SenhaTemporaria { param([string[]]$Linhas) ($Linhas | Where-Object { $_ -like 'SENHA_TEMPORARIA=*' } | Select-Object -First 1) -replace '^SENHA_TEMPORARIA=', '' }
function Remove-LinhaSenha { param([string[]]$Linhas) @($Linhas | Where-Object { $_ -notlike 'SENHA_TEMPORARIA=*' }) }

function Write-LogRedefinicao {
  param([string]$Arquivo, [string]$Texto)
  try { Add-Content -Path $Arquivo -Encoding UTF8 -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Texto) } catch { }
}

# Redefine (depois da confirmação). Devolve a senha temporária ou lança o erro; o log nunca recebe a senha.
function Invoke-RedefinirSenhaAdmin {
  param([string]$NodeExe, [string]$Backend, [string]$Arquivo, [string]$LoginAdmin, [string]$Operador)
  $env:REDEFINIR_OPERADOR = $Operador
  try { $r = Invoke-ScriptRedefinicao $NodeExe $Backend @('--login', $LoginAdmin, '--confirmar') }
  finally { Remove-Item Env:\REDEFINIR_OPERADOR -ErrorAction SilentlyContinue }
  $semSenha = Remove-LinhaSenha $r.Linhas
  $senha = Get-SenhaTemporaria $r.Linhas
  if ($r.Codigo -ne 0 -or -not $senha) {
    Write-LogRedefinicao $Arquivo "FALHOU: login '$LoginAdmin', por $Operador (código $($r.Codigo)): $($semSenha -join ' | ')"
    throw (($semSenha | Where-Object { $_ }) -join "`n")
  }
  Write-LogRedefinicao $Arquivo "Senha do administrador '$LoginAdmin' redefinida por $Operador (senha temporária mostrada só na tela)."
  return $senha
}

# ------------------------------------------------------------------ execução (o teste carrega só as funções acima)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host 'Execute como Administrador (botão direito no atalho ou no PowerShell > Executar como administrador).' -ForegroundColor Red
  if (-not $Confirmar) { Read-Host 'Pressione Enter para fechar' | Out-Null }
  exit 1
}
$fim = 0
try {
  Import-AmbienteBackend $EnvFile
  $operador = "$env:USERDOMAIN\$env:USERNAME"

  $lista = Invoke-ScriptRedefinicao $Node $BackendDir @('--listar')
  if ($lista.Codigo -ne 0) { throw ((Remove-LinhaSenha $lista.Linhas) -join "`n") }
  $json = ($lista.Linhas | Where-Object { $_ -like 'ADMINISTRADORES=*' } | Select-Object -First 1) -replace '^ADMINISTRADORES=', ''
  $admins = @(($json | ConvertFrom-Json) | ForEach-Object { $_ })   # PS 5.1: o array do JSON vem como um objeto só
  Write-Host ''
  Write-Host 'Administradores do e-Financeira:' -ForegroundColor Cyan
  $admins | Format-Table @{ n = 'Login'; e = { $_.login } }, @{ n = 'E-mail'; e = { $_.email } }, @{ n = 'Nome'; e = { $_.nome } },
    @{ n = 'Situação'; e = { if (-not $_.ativo) { 'inativo' } elseif ($_.bloqueado) { 'bloqueado' } else { 'ativo' } } } -AutoSize | Out-Host
  if (-not $admins.Count) { throw 'Nenhum administrador cadastrado neste banco.' }

  if (-not $Login) { $Login = (Read-Host 'Login do administrador que terá a senha redefinida').Trim() }
  if (-not $Login) { throw 'Nenhum login informado. Nada foi alterado.' }
  if (-not $Confirmar) {
    Write-Host ''
    Write-Host "A senha de '$Login' será trocada por uma senha temporária. As sessões abertas dele serão encerradas, o" -ForegroundColor Yellow
    Write-Host 'usuário será desbloqueado (e reativado, se estiver inativo) e terá de trocar a senha no próximo login.' -ForegroundColor Yellow
    if ((Read-Host 'Confirma? (digite SIM)') -ne 'SIM') { throw 'Cancelado: a confirmação não foi SIM. Nada foi alterado.' }
  }

  $senha = Invoke-RedefinirSenhaAdmin $Node $BackendDir $LogFile $Login $operador
  Write-Host ''
  Write-Host "Senha temporária de '$Login':" -ForegroundColor Green
  Write-Host "    $senha" -ForegroundColor White -BackgroundColor DarkGreen
  Write-Host ''
  Write-Host 'Anote e entregue ao administrador por um canal seguro. Ela NÃO fica gravada em lugar nenhum; no primeiro'
  Write-Host 'login o sistema pede uma senha nova. A redefinição ficou registrada na Auditoria.'
}
catch {
  Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
  $fim = 1
}
finally {
  Remove-Variable senha -ErrorAction SilentlyContinue
}
if (-not $Confirmar) { Read-Host 'Pressione Enter para fechar' | Out-Null }
exit $fim
