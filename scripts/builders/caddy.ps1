[CmdletBinding()]
param($Plan, $SourceRoot, $PackageDir, $CacheRoot)

$oldGoos = $env:GOOS
$oldGoarch = $env:GOARCH
$env:GOOS = "windows"
$env:GOARCH = "amd64"
try {
  $xcaddyExe = Get-ChildItem -Path (Join-Path $CacheRoot "toolchain/xcaddy") -Filter "xcaddy.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
  $tool = if ($xcaddyExe) { $xcaddyExe } else { "xcaddy" }
  $buildDir = Join-Path ([System.IO.Path]::GetTempPath()) ("xcaddy-build-" + [Guid]::NewGuid().ToString("N"))
  $null = New-Item -ItemType Directory -Force -Path $buildDir
  Push-Location $buildDir
  try {
    Invoke-Checked $tool @("build", $Plan.tag, "--with", "github.com/caddy-dns/dynu", "--output", (Join-Path $PackageDir "caddy.exe"))
  } finally {
    Pop-Location
    Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue
  }
} finally {
  $env:GOOS = $oldGoos
  $env:GOARCH = $oldGoarch
}
