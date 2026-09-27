<#
.SYNOPSIS
  Cache management and garbage collection for stale sources and unused toolchains.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-CacheGc {
  param(
    [object[]]$Plans,
    [string]$CacheDir
  )

  $sourcesCacheDir = Join-Path $CacheDir "sources"
  if ([System.IO.Directory]::Exists($sourcesCacheDir)) {
    $activeFingerprints = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $Plans) { $null = $activeFingerprints.Add($p.fingerprint) }
    $cachedDirs = [System.IO.Directory]::EnumerateDirectories($sourcesCacheDir)
    foreach ($dir in $cachedDirs) {
      $fp = [System.IO.Path]::GetFileName($dir)
      if (-not $activeFingerprints.Contains($fp)) {
        Write-Host "Pruning stale source from cache: $fp" -ForegroundColor Yellow
        [System.IO.Directory]::Delete($dir, $true)
      }
    }
  }

  $toolchainCacheDir = Join-Path $CacheDir "toolchain"
  if ([System.IO.Directory]::Exists($toolchainCacheDir)) {
    $activeTools = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $Plans) {
      foreach ($dep in @(Get-Prop $p.recipe "tool_dependencies" @())) {
        $null = $activeTools.Add([string]$dep)
      }
    }
    $cachedTools = [System.IO.Directory]::EnumerateDirectories($toolchainCacheDir)
    foreach ($toolDir in $cachedTools) {
      $toolName = [System.IO.Path]::GetFileName($toolDir)
      if (-not $activeTools.Contains($toolName)) {
        Write-Host "Pruning unused toolchain from cache: $toolName" -ForegroundColor Yellow
        [System.IO.Directory]::Delete($toolDir, $true)
      }
    }
  }
}
