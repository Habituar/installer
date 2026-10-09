# Teste das funções de configuração do scripts\postinstall.ps1, em memória e em pasta temporária — não toca na
# instalação da máquina. Uso:
#   powershell -ExecutionPolicy Bypass -File installer\tools\testar-postinstall-config.ps1
$ErrorActionPreference = 'Stop'
$tokens = $null; $erros = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\scripts\postinstall.ps1'), [ref]$tokens, [ref]$erros)
if ($erros.Count) { throw "postinstall.ps1 não compila: $($erros[0].Message)" }
function Carregar([string]$nome) {
  $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $nome }, $true) | Select-Object -First 1
  if (-not $fn) { throw "$nome não encontrada em scripts\postinstall.ps1" }
  Invoke-Expression "function global:$nome $($fn.Body.Extent.Text)"
}
'Read-GlobalDefaults', 'Merge-GlobalDefaults', 'Get-ModoInstalacao', 'Assert-ModoConfere', 'Write-MarcadorInstalacao' |
  ForEach-Object { Carregar $_ }

$falhas = 0
function Confere($condicao, $texto) { if ($condicao) { Write-Host "ok    $texto" } else { Write-Host "FALHA $texto" -ForegroundColor Red; $script:falhas++ } }
function Erro([scriptblock]$bloco) { try { & $bloco | Out-Null; return $null } catch { return $_.Exception.Message } }

# ---- Item 6: SUPORTE_CONTATO chega na instalação nova e na atualização
$globais = @(Read-GlobalDefaults (Join-Path $PSScriptRoot '..\config\global-defaults.env'))
Confere ($globais -contains 'SUPORTE_CONTATO=chamados.cfi@zapsistemas.com.br') 'global-defaults.env traz SUPORTE_CONTATO=chamados.cfi@zapsistemas.com.br'

$antigo = @('DB_TYPE=mssql', 'JWT_SECRET=dpapi:AAAA', 'LICENSE_PUBLIC_KEY_B64=velha')   # backend.env de uma 1.2.27
$m = Merge-GlobalDefaults $antigo $globais 6>$null
Confere ($m.Mudou) 'atualização: backend.env muda'
Confere (@($m.Linhas | Where-Object { $_ -eq 'SUPORTE_CONTATO=chamados.cfi@zapsistemas.com.br' }).Count -eq 1) 'atualização: SUPORTE_CONTATO é acrescentado'
Confere ($m.Linhas -contains 'DB_TYPE=mssql' -and $m.Linhas -contains 'JWT_SECRET=dpapi:AAAA') 'atualização: as outras linhas ficam como estão'
Confere (-not ($m.Linhas -contains 'LICENSE_PUBLIC_KEY_B64=velha')) 'atualização: valor global renovado é trocado'
$m2 = Merge-GlobalDefaults $m.Linhas $globais 6>$null
Confere (-not $m2.Mudou -and $m2.Linhas.Count -eq $m.Linhas.Count) 'atualização repetida: nada muda (sem linha duplicada)'

# ---- Item 2: instalação nova, atualização e incompleta, a partir do que está numa pasta de instalação de verdade
$base = Join-Path $env:TEMP ('teste-modo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
  function Pasta([string]$nome, [switch]$Env, [switch]$Marcador) {
    $cfg = Join-Path $base "$nome\config"; New-Item -ItemType Directory -Force $cfg | Out-Null
    if ($Env) { Set-Content (Join-Path $cfg 'backend.env') 'DB_TYPE=mssql' }
    if ($Marcador) { Set-Content (Join-Path $cfg 'instalacao.json') '{}' }
    $cfg
  }
  function ModoDa([string]$cfg, [bool]$servico) {
    Get-ModoInstalacao (Test-Path (Join-Path $cfg 'backend.env')) (Test-Path (Join-Path $cfg 'instalacao.json')) $servico
  }
  Confere ((ModoDa (Pasta 'vazia') $false) -eq 'nova') 'cenário 1 — instalação nova (pasta sem backend.env): nova'
  Confere ((ModoDa (Pasta 'vazia2') $true) -eq 'nova') 'sem backend.env é sempre nova, mesmo com um serviço antigo registrado'
  Confere ((ModoDa (Pasta 'v1227' -Env) $true) -eq 'atualizacao') 'cenário 2 — atualização da 1.2.27 (backend.env, sem marcador, serviço registrado): atualizacao'
  Confere ((ModoDa (Pasta 'v1228' -Env -Marcador) $true) -eq 'atualizacao') 'atualização de uma 1.2.28 (backend.env e marcador): atualizacao'
  Confere ((ModoDa (Pasta 'desinst' -Env -Marcador) $false) -eq 'atualizacao') 'reinstalação depois de desinstalar (config e marcador ficam, serviço não): atualizacao, como antes'
  Confere ((ModoDa (Pasta 'falhou' -Env) $false) -eq 'incompleta') 'cenário 3 — instalação nova que falhou (backend.env, sem marcador, sem serviço): incompleta'

  # Marcador: gravado no fim, com versão e modo; e o modo do instalador tem de bater com o do disco
  $cfg = Pasta 'marcador' -Env
  $versao = Join-Path $base 'versao.json'; Set-Content $versao '{"versao":"1.2.28","commit":"abc"}'
  Write-MarcadorInstalacao (Join-Path $cfg 'instalacao.json') 'incompleta' $versao
  $mk = Get-Content (Join-Path $cfg 'instalacao.json') -Raw | ConvertFrom-Json
  Confere ($mk.versao -eq '1.2.28' -and $mk.modo -eq 'incompleta' -and $mk.concluidaEm) 'marcador: versão, modo e data'
  Confere ((ModoDa $cfg $false) -eq 'atualizacao') 'depois do marcador, a próxima execução é atualização'
  Confere ($null -eq (Erro { Assert-ModoConfere 'incompleta' 'incompleta' })) 'modo do instalador igual ao do disco: segue'
  Confere ($null -eq (Erro { Assert-ModoConfere 'nova' $null })) 'sem modo do instalador (execução manual): segue com o do disco'
  Confere ((Erro { Assert-ModoConfere 'atualizacao' 'nova' }) -match "tratou esta pasta como 'nova'") 'modo divergente: para antes de mexer na configuração'
} finally { Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue }

# Trava: o único ponto que grava um backend.env novo está dentro do "if ($Fresh)" e recusa um backend.env existente
$fonte = Get-Content (Join-Path $PSScriptRoot '..\scripts\postinstall.ps1') -Raw
$gravacoes = [regex]::Matches($fonte, 'Set-Content -Path \$EnvFile -Value \$envLines')
$trava = [regex]::Match($fonte, "if \(Test-Path \`$EnvFile\) \{ throw ""config\\backend\.env já existe e não será recriado")
Confere ($gravacoes.Count -eq 1 -and $trava.Success -and $trava.Index -lt $gravacoes[0].Index) 'backend.env novo: um só ponto de gravação, logo depois da trava "já existe e não será recriado"'
Confere ($fonte -match '\$Fresh = \$Modo -eq ''nova''') '$Fresh vem do modo (nova = sem backend.env), não mais só da existência do backend.env'

if ($falhas) { Write-Host "$falhas falha(s)" -ForegroundColor Red; exit 1 }
Write-Host 'Todos os testes passaram.' -ForegroundColor Green
