[CmdletBinding()]
param($Plan, $SourceRoot, $PackageDir, $CacheRoot)

Push-Location $SourceRoot
try {
  Invoke-Checked "bun" @("install", "--frozen-lockfile")
  Invoke-Checked "bun" @("run", "build")
  $out = [string](Get-Prop $Plan.recipe "output_path" "dist")
  Copy-Item $out $PackageDir -Recurse -Force
} finally {
  Pop-Location
}
