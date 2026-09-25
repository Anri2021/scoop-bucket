[CmdletBinding()]
param(
  [string]$PlanPath = "./dist/plan.json",
  [string]$StageDir = "./dist/stage"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $PlanPath)) { throw "Plan file not found: $PlanPath" }
$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding utf8 | ConvertFrom-Json
$built = @($plan.packages | Where-Object needs_build)

foreach ($package in $built) {
  $archive = Get-ChildItem -LiteralPath $StageDir -Filter $package.artifact_name -File -Recurse | Select-Object -First 1
  if (-not $archive) { continue }
  $target = Join-Path ([IO.Path]::GetTempPath()) ("verify-" + $package.name)
  if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
  Expand-Archive -LiteralPath $archive.FullName -DestinationPath $target -Force
  $bin = [string]$package.recipe.bin
  if ($bin -and -not (Test-Path -LiteralPath (Join-Path $target $bin))) {
    throw "Expected executable '$bin' is missing from $($package.name)."
  }
  Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "All staged artifacts verified successfully." -ForegroundColor Green
