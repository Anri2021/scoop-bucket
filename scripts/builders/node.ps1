[CmdletBinding()]
param($Plan, $SourceRoot, $PackageDir, $CacheRoot)


  Invoke-Checked "corepack" @("enable")
  if (Test-Path "pnpm-lock.yaml") {
    Invoke-Checked "pnpm" @("install", "--frozen-lockfile")
    Invoke-Checked "pnpm" @("run", "build")
  } else {
    Invoke-Checked "npm" @("install", "--ignore-scripts")
    Invoke-Checked "npm" @("run", "build")
  }

  $entry = [string](Get-Prop $Plan.recipe "entrypoint" "")
  if (-not $entry) {
    if (Test-Path "package.json") {
      $pkgJson = Get-Content "package.json" -Raw | ConvertFrom-Json
      if ($pkgJson.bin) {
        $entry = if ($pkgJson.bin -is [string]) { $pkgJson.bin } else { ($pkgJson.bin.PSObject.Properties | Select-Object -First 1).Value }
      } elseif ($pkgJson.main) {
        $entry = $pkgJson.main
      }
    }
    if (-not $entry -and (Test-Path "index.js")) { $entry = "index.js" }
  }
  if (-not $entry) { throw "Entrypoint not found for $($Plan.name)" }

  $extraDirs = @(Get-Prop $Plan.recipe "output_dirs" @())
  $targets = @("bin", "build", "dist", "lib", "package.json", "package-lock.json", "pnpm-lock.yaml") + $extraDirs
  foreach ($p in ($targets | Select-Object -Unique)) {
    if (Test-Path $p) { Copy-Item $p $PackageDir -Recurse -Force }
  }

  Push-Location $PackageDir
  try {
    if (Test-Path "pnpm-lock.yaml") {
      Invoke-Checked "pnpm" @("install", "--prod", "--prefer-offline", "--config.node-linker=hoisted")
    } else {
      Invoke-Checked "npm" @("install", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund", "--prefer-offline")
    }
  } finally {
    Pop-Location
  }

  $pre = if (@(Get-Prop $Plan.recipe "persist" @()).Count -gt 0) { 'cd /d "%~dp0"' } else { "" }
  Write-CmdShim -Path (Join-Path $PackageDir "$($Plan.name).cmd") -Command ('node "%~dp0{0}" %*' -f ($entry -replace '/', '\')) -PreCommand $pre

