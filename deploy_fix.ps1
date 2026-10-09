# Deploy script — Central de Vendas ArznStoreSP
# Coloque seu token do GitHub abaixo ou defina a variavel de ambiente GH_TOKEN
$token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { Read-Host "Cole seu GitHub token" }

$repo  = "arznstoresp/central-vendas"
$path  = "index.html"
$file  = "$PSScriptRoot\index.html"

if (!(Test-Path $file)) {
  Write-Host "ERRO: arquivo nao encontrado em $file" -ForegroundColor Red
  exit 1
}

$bytes   = [System.IO.File]::ReadAllBytes($file)
$content = [Convert]::ToBase64String($bytes)

$headers = @{
  Authorization = "token $token"
  "User-Agent"  = "deploy-script"
}

$sha = (Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/contents/$path" -Headers $headers).sha

$body = @{
  message = "feat: catalogo completo com renderCatalog, openProd, addToCart, historico"
  content = $content
  sha     = $sha
} | ConvertTo-Json -Compress

Invoke-RestMethod -Method Put `
  -Uri "https://api.github.com/repos/$repo/contents/$path" `
  -Headers $headers `
  -Body $body `
  -ContentType "application/json"

Write-Host "Deploy concluido! Aguarde ~30s e acesse https://central-vendas-six.vercel.app" -ForegroundColor Green
