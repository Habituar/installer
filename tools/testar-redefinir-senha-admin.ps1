# Teste do scripts\redefinir-senha-admin.ps1 (item 3 das pendências 1.2.28) contra um banco DESCARTÁVEL: cria um
# administrador só do teste, redefine a senha dele pelo mesmo caminho do atalho (funções do script + o
# dist\scripts\redefinirSenhaAdmin.js do backend) e confere hash, troca obrigatória, Auditoria e log; no fim apaga o
# usuário e os registros de Auditoria dele. Não precisa de administrador do Windows (a checagem fica fora das funções).
# Uso (backend já compilado com npm run build):
#   powershell -ExecutionPolicy Bypass -File installer\tools\testar-redefinir-senha-admin.ps1 `
#     -EnvFile <.env de um banco de TESTE> -Backend <pasta efinanceira-back>
# Recusa banco cujo nome não contenha "teste", "grupod" ou "descart".
param([Parameter(Mandatory = $true)][string]$EnvFile, [Parameter(Mandatory = $true)][string]$Backend, [string]$NodeExe = 'node')
$ErrorActionPreference = 'Stop'
$tokens = $null; $erros = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\scripts\redefinir-senha-admin.ps1'), [ref]$tokens, [ref]$erros)
if ($erros.Count) { throw "redefinir-senha-admin.ps1 não compila: $($erros[0].Message)" }
foreach ($nome in 'Import-AmbienteBackend', 'Invoke-ScriptRedefinicao', 'Get-SenhaTemporaria', 'Remove-LinhaSenha', 'Write-LogRedefinicao', 'Invoke-RedefinirSenhaAdmin') {
  $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $nome }, $true) | Select-Object -First 1
  if (-not $fn) { throw "$nome não encontrada em scripts\redefinir-senha-admin.ps1" }
  Invoke-Expression "function global:$nome $($fn.Body.Extent.Text)"
}
Add-Type -AssemblyName System.Security
$falhas = 0
function Confere($condicao, $texto) { if ($condicao) { Write-Host "ok    $texto" } else { Write-Host "FALHA $texto" -ForegroundColor Red; $script:falhas++ } }

Import-AmbienteBackend $EnvFile
if ($env:DB_NAME -notmatch 'teste|grupod|descart') { throw "Banco '$($env:DB_NAME)' não parece descartável: o teste só roda em banco de teste." }
if (-not (Test-Path (Join-Path $Backend 'dist\scripts\redefinirSenhaAdmin.js'))) { throw 'Compile o backend antes (npm run build).' }
$Backend = (Resolve-Path $Backend).Path
$LOGIN = 'teste.redefinicao'
$tmp = Join-Path $env:TEMP ('teste-redefinicao-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null

# Apoio em Node (cria, consulta e apaga o usuário do teste) com o backend compilado
$url = { param($p) ([Uri](Join-Path $Backend $p)).AbsoluteUri }
$apoio = @'
import ds from '__DS__';
import { Usuario, Cliente, LogAuditoria } from '__ENT__';
import bcrypt from 'bcryptjs';
const [acao, login, senha] = process.argv.slice(2);
await ds.initialize();
try {
  const usu = ds.getRepository(Usuario), aud = ds.getRepository(LogAuditoria);
  const u = await usu.findOne({ where: { login } });
  if (acao === 'criar') {
    if (u) { await aud.delete({ recursoId: u.id }); await usu.delete({ id: u.id }); }
    const c = (await ds.getRepository(Cliente).find({ take: 1 }))[0];
    await usu.save(usu.create({ clienteId: c.id, login, nome: 'Teste redefinição', email: 'teste.redefinicao@teste.local',
      senhaHash: await bcrypt.hash('Antiga@2026x', 4), perfil: 'Administrador', ativo: false, tentativasLoginFalhas: 5,
      bloqueadoAte: new Date(Date.now() + 600000) }));
  } else if (acao === 'conferir') {
    const auditoria = await aud.find({ where: { recursoId: u.id } });
    console.log(JSON.stringify({ senhaCerta: await bcrypt.compare(senha, u.senhaHash), antigaCerta: await bcrypt.compare('Antiga@2026x', u.senhaHash),
      trocar: u.trocarSenhaNoLogin, ativo: u.ativo, tentativas: u.tentativasLoginFalhas, bloqueadoAte: u.bloqueadoAte, tokenVersao: u.tokenVersao,
      auditoria: auditoria.map((a) => ({ usuarioId: a.usuarioId, acao: a.acao, detalhes: a.detalhes })) }));
  } else if (acao === 'apagar' && u) {
    await aud.delete({ recursoId: u.id }); await usu.delete({ id: u.id });
  }
} finally { await ds.destroy(); }
'@
$apoio = $apoio.Replace('__DS__', (& $url 'dist\lib\dataSource.js')).Replace('__ENT__', (& $url 'dist\entities\index.js'))
$apoioJs = Join-Path $Backend ('teste-redefinicao-apoio-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.mjs')   # dentro do backend: acha o bcryptjs
[IO.File]::WriteAllText($apoioJs, $apoio, (New-Object Text.UTF8Encoding $false))
function Apoio([string[]]$a) {
  Push-Location $Backend
  try { $s = & $NodeExe $apoioJs @a 2>&1 | ForEach-Object { "$_" }; if ($LASTEXITCODE -ne 0) { throw "apoio $($a[0]) falhou: $s" }; $s }
  finally { Pop-Location }
}

try {
  Apoio @('criar', $LOGIN) | Out-Null
  $log = Join-Path $tmp 'redefinir-senha-admin.log'

  $lista = Invoke-ScriptRedefinicao $NodeExe $Backend @('--listar')
  $json = ($lista.Linhas | Where-Object { $_ -like 'ADMINISTRADORES=*' }) -replace '^ADMINISTRADORES=', ''
  $adm = @(($json | ConvertFrom-Json) | ForEach-Object { $_ }) | Where-Object { $_.login -eq $LOGIN }
  Confere ($lista.Codigo -eq 0 -and $adm -and -not $adm.ativo -and $adm.bloqueado) 'lista os administradores com a situação (o do teste: inativo e bloqueado)'

  $sem = Invoke-ScriptRedefinicao $NodeExe $Backend @('--login', $LOGIN)
  $antes = Apoio @('conferir', $LOGIN, 'x') | ConvertFrom-Json
  Confere ($sem.Codigo -eq 3 -and $antes.antigaCerta) 'sem --confirmar: recusa (código 3) e nada muda'

  $senha = Invoke-RedefinirSenhaAdmin $NodeExe $Backend $log $LOGIN 'TESTE\script'
  $depois = Apoio @('conferir', $LOGIN, $senha) | ConvertFrom-Json
  Confere ($senha.Length -eq 16) 'senha temporária devolvida a quem chamou (16 caracteres)'
  Confere ($depois.senhaCerta -and -not $depois.antigaCerta) 'senha trocada: a temporária entra, a antiga não'
  Confere ($depois.trocar -and $depois.ativo -and $depois.tentativas -eq 0 -and -not $depois.bloqueadoAte) 'troca obrigatória no próximo login; reativado e desbloqueado'
  Confere ($depois.tokenVersao -ge 1) 'sessões abertas revogadas (tokenVersao)'
  $a = @($depois.auditoria)
  Confere ($a.Count -eq 1 -and $a[0].usuarioId -eq 'servidor:TESTE\script' -and $a[0].acao -eq 'redefinir_senha') 'Auditoria: redefinir_senha por servidor:<usuário do Windows>'
  Confere (-not (($a | ConvertTo-Json -Depth 5) -match [regex]::Escape($senha))) 'a senha não está na Auditoria'
  $textoLog = Get-Content $log -Raw
  Confere ($textoLog -match "Senha do administrador '$LOGIN' redefinida por TESTE\\script") 'log registra quem redefiniu e de quem'
  Confere (-not ($textoLog -match [regex]::Escape($senha))) 'a senha não está no log'

  $erro = $null
  try { Invoke-RedefinirSenhaAdmin $NodeExe $Backend $log 'nao.existe' 'TESTE\script' | Out-Null } catch { $erro = $_.Exception.Message }
  Confere ($erro -match 'Nenhum administrador com o login') 'login inexistente: erro claro, nada muda'
  Confere ((Get-Content $log -Raw) -match "FALHOU: login 'nao.existe'") 'falha também vai para o log'
} finally {
  try { Apoio @('apagar', $LOGIN) | Out-Null } catch { Write-Host "Não consegui apagar o usuário do teste: $_" -ForegroundColor Yellow }
  Remove-Item $apoioJs -Force -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($falhas) { Write-Host "$falhas falha(s)" -ForegroundColor Red; exit 1 }
Write-Host 'Todos os testes passaram.' -ForegroundColor Green
