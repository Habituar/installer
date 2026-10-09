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
  # install-aviso.txt como o setup (Node) grava: UTF-8 com BOM, CRLF, acentos
  $aviso = Join-Path $tmp 'install-aviso.txt'
  [IO.File]::WriteAllText($aviso, "Banco j$([char]0xE1) configurado: o administrador informado N$([char]0xC3)O foi criado.`r`nInstitui$([char]0xE7)$([char]0xE3)o: Teste`r`n", (New-Object Text.UTF8Encoding $true))
  $p = Start-Process -FilePath (Join-Path $tmp 'testar-codigo-instalador.exe') -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', "/saida=$saida", "/aviso=$aviso" -Wait -PassThru
  if (-not (Test-Path $saida)) { throw "O teste não gravou o resultado (código $($p.ExitCode))." }
  $linhas = @(Get-Content $saida -Encoding UTF8 | Where-Object { $_ })
  # Item 3: atalho do menu Iniciar com o MESMO nome que a tela de login cita (front, ATALHO_REDEFINIR_SENHA_ADMIN)
  $iss = Get-Content (Join-Path $PSScriptRoot '..\efinanceira.iss') -Raw
  $atalho = $iss -match '(?m)^Name: "\{group\}\\Redefinir senha do administrador"; Filename: "powershell\.exe"; Parameters: "[^"]*""\{app\}\\scripts\\redefinir-senha-admin\.ps1""'
  $linhas += $(if ($atalho -and (Test-Path (Join-Path $PSScriptRoot '..\scripts\redefinir-senha-admin.ps1'))) {
    'ok    atalho "Redefinir senha do administrador" no menu Iniciar aponta para scripts\redefinir-senha-admin.ps1' } else {
    'FALHA atalho "Redefinir senha do administrador" ausente ou apontando para outro script' })
  $linhas | ForEach-Object { if ($_ -like 'FALHA*') { Write-Host $_ -ForegroundColor Red } else { Write-Host $_ } }
  $falhas = @($linhas | Where-Object { $_ -like 'FALHA*' }).Count
  if (-not $linhas.Count) { throw 'Nenhuma verificação executada.' }
  if ($falhas) { Write-Host "$falhas falha(s)" -ForegroundColor Red; exit 1 }
  Write-Host "Todos os testes passaram ($($linhas.Count))." -ForegroundColor Green
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
