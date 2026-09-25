[CmdletBinding()]
param($Plan, $SourceRoot, $PackageDir, $CacheRoot)

Push-Location $SourceRoot
try {
  $entry = [string](Get-Prop $Plan.recipe "entrypoint" (Get-Prop $Plan.recipe "bin"))
  Copy-Item $entry $PackageDir -Force
} finally {
  Pop-Location
}
