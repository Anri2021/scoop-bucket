[CmdletBinding()]
param($Plan, $SourceRoot, $PackageDir, $CacheRoot)

Invoke-Checked "cargo" @("build", "--locked", "--release")
Get-ChildItem "target/release/*.exe" -File | Copy-Item -Destination $PackageDir -Force
