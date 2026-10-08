# Teste da instalação dos certificados de criptografia da RFB (Install-CertificadosRfb, scripts\postinstall.ps1),
# em pastas temporárias — não toca na instalação da máquina. Uso:
#   powershell -ExecutionPolicy Bypass -File installer\tools\testar-certificados-rfb.ps1 [-Pacote <pasta com os .cer>]
param([string]$Pacote = (Join-Path $PSScriptRoot '..\..\efinanceira-back\src\recursos\rfb'))
$ErrorActionPreference = 'Stop'
$tokens = $null; $erros = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\scripts\postinstall.ps1'), [ref]$tokens, [ref]$erros)
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-CertificadosRfb' }, $true) | Select-Object -First 1
if (-not $fn) { throw 'Install-CertificadosRfb não encontrada em scripts\postinstall.ps1' }
Invoke-Expression $fn.Extent.Text

$base = Join-Path $env:TEMP ('teste-certs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$App = Join-Path $base 'app'; $ConfigDir = Join-Path $App 'config'
$origem = Join-Path $App 'backend\dist\recursos\rfb'
New-Item -ItemType Directory -Force $origem, $ConfigDir | Out-Null
Copy-Item (Join-Path $Pacote '*.cer') $origem
$prod = Join-Path $ConfigDir 'rfb\cert-criptografia-producao.cer'
$falhas = 0
function Confere($condicao, $texto) { if ($condicao) { Write-Host "ok   $texto" } else { Write-Host "FALHA $texto" -ForegroundColor Red; $script:falhas++ } }
$cert = { param($p) New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $p }
$req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest('CN=efinanceira.receita.fazenda.gov.br', [System.Security.Cryptography.RSA]::Create(2048),
  [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
try {
  Install-CertificadosRfb | Out-Null
  Confere ((Get-ChildItem (Join-Path $ConfigDir 'rfb') -Filter *.cer).Count -eq 2) 'instalação nova: os dois certificados vão para config\rfb'

  $renovado = $req.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddYears(2))
  [IO.File]::WriteAllBytes($prod, $renovado.Export('Cert'))
  Install-CertificadosRfb | Out-Null
  Confere ((& $cert $prod).Thumbprint -eq $renovado.Thumbprint) 'atualização: certificado renovado pelo Administrador (vence depois) é mantido'

  $velho = $req.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-30), [DateTimeOffset]::Now.AddDays(5))
  [IO.File]::WriteAllBytes($prod, $velho.Export('Cert'))
  Install-CertificadosRfb | Out-Null
  $doPacote = & $cert (Join-Path $origem 'cert-criptografia-producao.cer')
  Confere ((& $cert $prod).Thumbprint -eq $doPacote.Thumbprint) 'atualização: certificado mais velho é trocado pelo do pacote'
  Confere (Test-Path "$prod.anterior") 'o certificado substituído fica como .anterior'
} finally {
  Remove-Item -Recurse -Force $base
}
if ($falhas) { throw "$falhas verificação(ões) falharam" }
Write-Host 'Todas as verificações passaram.'
