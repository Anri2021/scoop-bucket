[CmdletBinding()]
param($Plan, $SourceRoot, $PackageDir, $CacheRoot)

$entry = [string](Get-Prop $Plan.recipe "entrypoint" "")
$proj = if ($entry -and (Test-Path (Join-Path $SourceRoot $entry))) {
  Join-Path $SourceRoot $entry
} elseif ($entry -and (Test-Path $entry)) {
  $entry
} else {
  (Get-ChildItem -Path $SourceRoot -Filter "*.*proj" -Recurse -File | Select-Object -First 1).FullName
}
if (-not $proj) { throw "No .NET project file found in '$SourceRoot'." }
$customArgs = @(Get-Prop $Plan.recipe "build_args" @())
Invoke-Checked "dotnet" (@("publish", $proj, "-c", "Release", "-o", $PackageDir) + $customArgs)

