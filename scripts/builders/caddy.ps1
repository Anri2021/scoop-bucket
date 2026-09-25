[CmdletBinding()]
param($Plan, $SourceRoot, $PackageDir, $CacheRoot)

$oldGoos = $env:GOOS
$oldGoarch = $env:GOARCH
$env:GOOS = "windows"
$env:GOARCH = "amd64"
try {
  Invoke-Checked "xcaddy" @("build", $Plan.tag, "--with", "github.com/caddy-dns/dynu", "--output", (Join-Path $PackageDir "caddy.exe"))
} finally {
  $env:GOOS = $oldGoos
  $env:GOARCH = $oldGoarch
}
