# Teste da conferência de SHA-256 das dependências do build (Read-DepsSha256, Assert-DepSha256 e Get-Dep do
# build.ps1, contra installer\deps.sha256), em pasta temporária — não executa o build nem toca em installer\deps\.
# Uso:
#   powershell -ExecutionPolicy Bypass -File installer\tools\testar-deps-sha256.ps1 [-Deps <pasta deps\ a conferir>]
# Com -Deps, também confere os arquivos reais daquela pasta com o deps.sha256 do repositório.
param([string]$Deps = '')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$tokens = $null; $erros = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\build.ps1'), [ref]$tokens, [ref]$erros)
if ($erros.Count) { throw "build.ps1 não compila: $($erros[0].Message)" }
foreach ($nomeFn in 'Read-DepsSha256', 'Assert-DepSha256', 'Get-Dep') {
  $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $nomeFn }, $true) | Select-Object -First 1
  if (-not $fn) { throw "$nomeFn não encontrada em build.ps1" }
  Invoke-Expression $fn.Extent.Text
}

$falhas = 0
function Confere($condicao, $texto) { if ($condicao) { Write-Host "ok    $texto" } else { Write-Host "FALHA $texto" -ForegroundColor Red; $script:falhas++ } }
# Roda o bloco; devolve a mensagem do erro, ou $null se não falhou
function Erro([scriptblock]$bloco) { try { & $bloco | Out-Null; return $null } catch { return $_.Exception.Message } }
function Sha([string]$p) { (Get-FileHash $p -Algorithm SHA256).Hash.ToLowerInvariant() }

# deps.sha256 do repositório: bem formado, com as três dependências
$real = Read-DepsSha256 (Join-Path $PSScriptRoot '..\deps.sha256')
Confere ($real.Count -eq 3 -and $real.ContainsKey('postgresql-installer.exe') -and $real.ContainsKey('WinSW-x64.exe') -and
  $real.ContainsKey('node-v22.14.0-win-x64.zip')) 'deps.sha256 registra PostgreSQL, Node e WinSW'
Confere ($real['postgresql-installer.exe'].Url -like '*postgresql-16.15-5-windows-x64.exe') 'PostgreSQL registrado é o 16.15-5'

$base = Join-Path $env:TEMP ('teste-deps-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$origem = Join-Path $base 'origem'; $pasta = Join-Path $base 'deps'
New-Item -ItemType Directory -Force $origem, $pasta | Out-Null
try {
  $fonte = Join-Path $origem 'pg.exe'
  [IO.File]::WriteAllBytes($fonte, [byte[]](1..200))
  $url = ([Uri]$fonte).AbsoluteUri   # file:///…: o Invoke-WebRequest do Get-Dep "baixa" sem rede
  $certo = Sha $fonte
  $errado = 'a' * 64
  $lista = Join-Path $base 'deps.sha256'
  Set-Content $lista -Encoding UTF8 -Value @('# teste', '', "$certo  postgresql-installer.exe  16.15-5  $url")
  $reg = Read-DepsSha256 $lista
  $dest = Join-Path $pasta 'postgresql-installer.exe'

  # 1. hash certo passa — no download e em cache
  Confere ($null -eq (Erro { Get-Dep $url $dest $reg })) 'hash certo: o download é aceito'
  Confere ((Test-Path $dest) -and -not (Test-Path "$dest.part")) 'hash certo: o arquivo vai para deps\ (sem .part sobrando)'
  Confere ($null -eq (Erro { Get-Dep $url $dest $reg })) 'hash certo: o arquivo em cache é aceito'

  # 2. hash errado falha — no arquivo em cache (antes era aceito pelo nome) e no download
  [IO.File]::WriteAllBytes($dest, [byte[]](1..199))   # arquivo trocado/corrompido em deps\
  $antes = Sha $dest
  $msg = Erro { Get-Dep $url $dest $reg }
  Confere ($msg -and $msg -match 'não confere' -and $msg.Contains($dest) -and $msg.Contains($certo) -and $msg.Contains($antes)) `
    'hash errado em cache: falha mostrando arquivo, hash esperado e hash obtido'
  Confere ((Test-Path $dest) -and (Sha $dest) -eq $antes) 'hash errado em cache: o arquivo não é apagado nem baixado de novo'

  Remove-Item $dest
  $regErrado = Read-DepsSha256 $lista
  $regErrado['postgresql-installer.exe'].Sha256 = $errado
  $msg = Erro { Get-Dep $url $dest $regErrado }
  Confere ($msg -and $msg -match 'não confere' -and $msg.Contains($errado) -and $msg.Contains($certo)) 'hash errado no download: falha com esperado e obtido'
  Confere (-not (Test-Path $dest) -and (Test-Path "$dest.rejeitado")) 'hash errado no download: não vai para deps\; fica como .rejeitado'
  Confere ($null -ne (Erro { Assert-DepSha256 $fonte 'postgresql-installer.exe' $regErrado })) 'Assert-DepSha256: hash errado falha'
  Confere ($null -eq (Erro { Assert-DepSha256 $fonte 'postgresql-installer.exe' $reg })) 'Assert-DepSha256: hash certo passa'

  # 3. arquivo sem hash registrado falha — sem baixar nem conferir nada
  $semRegistro = Join-Path $pasta 'WinSW-x64.exe'
  [IO.File]::WriteAllBytes($semRegistro, [byte[]](1..10))
  $msg = Erro { Get-Dep $url $semRegistro $reg }
  Confere ($msg -and $msg -match 'Sem SHA-256 registrado para WinSW-x64.exe') 'arquivo sem hash registrado: falha (mesmo já estando em deps\)'
  $msg = Erro { Get-Dep $url (Join-Path $pasta 'outro.zip') $reg }
  Confere ($msg -match 'Sem SHA-256 registrado' -and -not (Test-Path (Join-Path $pasta 'outro.zip.part')) -and
    -not (Test-Path (Join-Path $pasta 'outro.zip'))) 'arquivo sem hash registrado: falha antes de baixar'
  Confere ($null -ne (Erro { Assert-DepSha256 $semRegistro 'WinSW-x64.exe' $reg })) 'Assert-DepSha256: sem registro falha'

  # Origem diferente da registrada (ex.: -PgInstallerUrl de outra versão sem registrar o hash): falha
  $msg = Erro { Get-Dep 'https://get.enterprisedb.com/postgresql/postgresql-16.4-1-windows-x64.exe' $dest $reg }
  Confere ($msg -match 'não é a registrada') 'origem diferente da registrada em deps.sha256: falha'

  # deps.sha256 mal formado: falha dizendo a linha
  Set-Content $lista -Encoding UTF8 -Value @("$certo  postgresql-installer.exe")
  $msg = Erro { Read-DepsSha256 $lista }
  Confere ($msg -match 'linha 1') 'deps.sha256 com linha incompleta: falha indicando a linha'
} finally {
  Remove-Item -Recurse -Force $base
}

if ($Deps) {
  foreach ($nome in $real.Keys) {
    $arq = Join-Path $Deps $nome
    if (-not (Test-Path $arq)) { Write-Host "--    $nome ausente em $Deps" ; continue }
    Confere ($null -eq (Erro { Assert-DepSha256 $arq $nome $real })) "$Deps\$nome confere com deps.sha256"
  }
}

if ($falhas) { Write-Host "$falhas falha(s)" -ForegroundColor Red; exit 1 }
Write-Host 'Todos os testes passaram.' -ForegroundColor Green
