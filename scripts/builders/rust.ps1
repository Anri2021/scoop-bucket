[CmdletBinding()]
param($Plan, $SourceRoot, $PackageDir, $CacheRoot)

Push-Location $SourceRoot
try {
  Invoke-Checked "cargo" @("build", "--locked", "--release")
  Get-ChildItem "target/release/*.exe" -File | Copy-Item -Destination $PackageDir -Force
} finally {
  Pop-Location
}
