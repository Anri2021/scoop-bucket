[CmdletBinding()]
param(
  [string]$PlanPath = "./dist/plan.json",
  [string]$Repository = $env:GITHUB_REPOSITORY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
  Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
}
$env:PATH = "$HOME\scoop\shims;$env:PATH"

scoop bucket add anri "https://github.com/$Repository"

$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding utf8 | ConvertFrom-Json
$builtPackages = @($plan.packages | Where-Object {
  $_.needs_build -and (Test-Path "./bucket/$($_.name).json") -and ((Get-Content "./bucket/$($_.name).json" -Raw | ConvertFrom-Json).version -eq $_.version)
})

foreach ($pkg in $builtPackages) {
  Write-Host "Smoke testing $($pkg.name)..." -ForegroundColor Cyan
  scoop install "anri/$($pkg.name)"

  $bins = @($pkg.recipe.bin)
  foreach ($bin in $bins) {
    $cmdName = [IO.Path]::GetFileNameWithoutExtension($bin)
    if (-not (Get-Command $cmdName -ErrorAction SilentlyContinue)) {
      throw "Shim '$cmdName' for package '$($pkg.name)' was not created properly."
    }
  }
}
Write-Host "Smoke tests completed successfully." -ForegroundColor Green
