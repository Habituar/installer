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
'Read-GlobalDefaults', 'Merge-GlobalDefaults' | ForEach-Object { Carregar $_ }

$falhas = 0
function Confere($condicao, $texto) { if ($condicao) { Write-Host "ok    $texto" } else { Write-Host "FALHA $texto" -ForegroundColor Red; $script:falhas++ } }

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

if ($falhas) { Write-Host "$falhas falha(s)" -ForegroundColor Red; exit 1 }
Write-Host 'Todos os testes passaram.' -ForegroundColor Green
