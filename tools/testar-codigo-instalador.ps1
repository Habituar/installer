# Teste do código Pascal real do instalador (codigo-comum.iss): compila tools\testar-codigo-instalador.iss com o
# ISCC numa pasta temporária e executa o .exe de teste, que não instala nada — só grava "ok"/"FALHA" de cada
# verificação. Não precisa de administrador nem do stage\. Uso:
#   powershell -ExecutionPolicy Bypass -File installer\tools\testar-codigo-instalador.ps1
$ErrorActionPreference = 'Stop'
$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") |
  Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 não encontrado.' }

$tmp = Join-Path $env:TEMP ('teste-codigo-instalador-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null
try {
  & $iscc /Q "/O$tmp" (Join-Path $PSScriptRoot 'testar-codigo-instalador.iss')
  if ($LASTEXITCODE -ne 0) { throw "ISCC falhou ao compilar o teste (código $LASTEXITCODE)." }
  $saida = Join-Path $tmp 'resultado.txt'
  $p = Start-Process -FilePath (Join-Path $tmp 'testar-codigo-instalador.exe') -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', "/saida=$saida" -Wait -PassThru
  if (-not (Test-Path $saida)) { throw "O teste não gravou o resultado (código $($p.ExitCode))." }
  $linhas = @(Get-Content $saida -Encoding UTF8 | Where-Object { $_ })
  $linhas | ForEach-Object { if ($_ -like 'FALHA*') { Write-Host $_ -ForegroundColor Red } else { Write-Host $_ } }
  $falhas = @($linhas | Where-Object { $_ -like 'FALHA*' }).Count
  if (-not $linhas.Count) { throw 'Nenhuma verificação executada.' }
  if ($falhas) { Write-Host "$falhas falha(s)" -ForegroundColor Red; exit 1 }
  Write-Host "Todos os testes passaram ($($linhas.Count))." -ForegroundColor Green
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
