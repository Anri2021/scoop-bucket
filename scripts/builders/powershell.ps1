[CmdletBinding()]
param($Plan, $SourceRoot, $PackageDir, $CacheRoot)

$entry = [string](Get-Prop $Plan.recipe "entrypoint" (Get-Prop $Plan.recipe "bin"))
Copy-Item $entry $PackageDir -Force
