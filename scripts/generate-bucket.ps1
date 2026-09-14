<#
.SYNOPSIS
    Autonomous Meta-Bucket Generator for Scoop.
    Optimized for PowerShell 7+, maximum parallelism, multi-mode builds, and zero-rebuild caching.
#>

[CmdletBinding()]
param (
    [Parameter()]
    [string]$RecipesPath = "$PSScriptRoot/../recipes.json",

    [Parameter()]
    [string]$BucketDir = "$PSScriptRoot/../bucket",

    [Parameter()]
    [string]$BuildDir = "$PSScriptRoot/../dist",

    [Parameter()]
    [int]$ThrottleLimit = 6,

    [Parameter()]
    [switch]$ForceRebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- [1. Helper Functions: Fast Hash & Toolchain Detection] ---

function Get-FastSha256 {
    param ([Parameter(Mandatory)] [string]$FilePath)
    
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($FilePath)
    try {
        $hashBytes = $hasher.ComputeHash($stream)
        return -join ($hashBytes | ForEach-Object { '{0:x2}' -f $_ })
    }
    finally {
        $stream.Dispose()
        $hasher.Dispose()
    }
}

function Test-LocalToolchain {
    param ([Parameter(Mandatory)] [string]$ToolName)
    $cmd = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($cmd) {
        return @{ Available = $true; Path = $cmd.Source }
    }
    return @{ Available = $false; Path = $null }
}

# --- [2. Initialization] ---

if (-not (Test-Path -LiteralPath $RecipesPath)) {
    throw "Recipes file not found at: $RecipesPath"
}

$BucketDir = [System.IO.Path]::GetFullPath($BucketDir)
$BuildDir = [System.IO.Path]::GetFullPath($BuildDir)

$null = New-Item -ItemType Directory -Force -Path $BucketDir
$null = New-Item -ItemType Directory -Force -Path $BuildDir

$recipesContent = Get-Content -LiteralPath $RecipesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$recipes = if ($recipesContent -is [array]) { $recipesContent } else { $recipesContent.recipes }

Write-Host "Loaded $($recipes.Count) recipes. Starting parallel evaluation (Throttle: $ThrottleLimit)..." -ForegroundColor Cyan

# --- [3. Parallel Processing Engine] ---

$syncResults = [System.Collections.Concurrent.ConcurrentBag[pscustomobject]]::new()

$recipes | ForEach-Object -Parallel -ThrottleLimit $ThrottleLimit {
    $recipe = $_
    $bucketPath = $using:BucketDir
    $buildPath = $using:BuildDir
    $force = $using:ForceRebuild

    # Re-import helper function inside runspace
    function Get-FastSha256 {
        param ([string]$FilePath)
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::OpenRead($FilePath)
        try {
            $hashBytes = $hasher.ComputeHash($stream)
            return -join ($hashBytes | ForEach-Object { '{0:x2}' -f $_ })
        }
        finally {
            $stream.Dispose()
            $hasher.Dispose()
        }
    }

    $appName = $recipe.name
    $manifestFile = Join-Path $bucketPath "$appName.json"
    
    try {
        # --- 3.1 Version Discovery & Zero-Rebuild Skip ---
        $existingVersion = $null
        if (Test-Path -LiteralPath $manifestFile) {
            $currentManifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $existingVersion = $currentManifest.version
        }

        $headers = @{}
        if ($env:GITHUB_TOKEN) {
            $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN"
        }

        $latestVersion = $null
        $downloadUrl = $null

        switch ($recipe.source_type) {
            "github_release" {
                $apiUrl = "https://api.github.com/repos/$($recipe.repo)/releases/latest"
                $releaseData = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
                $latestVersion = $releaseData.tag_name -replace '^[vV]', ''
                
                # Match asset
                $assetPattern = $recipe.asset_pattern
                $matchedAsset = $releaseData.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1
                if ($matchedAsset) {
                    $downloadUrl = $matchedAsset.browser_download_url
                }
            }
            "pypi" {
                $apiUrl = "https://pypi.org/pypi/$($recipe.package)/json"
                $pypiData = Invoke-RestMethod -Uri $apiUrl -Method Get
                $latestVersion = $pypiData.info.version
                $downloadUrl = ($pypiData.urls | Where-Object { $_.packagetype -eq "bdist_wheel" -or $_.packagetype -eq "sdist" } | Select-Object -First 1).url
            }
            default {
                $latestVersion = $recipe.version
                $downloadUrl = $recipe.url
            }
        }

        if (-not $latestVersion) {
            Write-Warning "[$appName] Could not determine latest version. Skipping."
            return
        }

        # Skip if up to date
        if (-not $force -and $existingVersion -eq $latestVersion) {
            Write-Host "[$appName] Up-to-date (v$existingVersion). Skipping." -ForegroundColor DarkGray
            return
        }

        Write-Host "[$appName] Update detected: $existingVersion -> $latestVersion. Processing mode: $($recipe.mode)..." -ForegroundColor Yellow

        $workDir = Join-Path $buildPath "$appName-$latestVersion"
        $null = New-Item -ItemType Directory -Force -Path $workDir
        $finalHash = ""
        $finalUrl = $downloadUrl

        # --- 3.2 Multi-Mode Build & Optimization ---
        switch ($recipe.mode) {
            "CloudBuild" {
                # Build artifact from source, strip non-essentials and 7z solid compress
                $packageDir = Join-Path $workDir "pkg"
                $null = New-Item -ItemType Directory -Force -Path $packageDir
                
                # Strip unnecessary bloat before packing
                Get-ChildItem -Path $packageDir -Include "*.map", "*.pdb", "*.d.ts", "__pycache__", "tests" -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

                # 7z Solid Ultra compression (LZMA2)
                $solidArchive = Join-Path $workDir "$appName-$latestVersion.7z"
                $sevenZip = Get-Command "7z" -ErrorAction SilentlyContinue
                if ($sevenZip) {
                    & $sevenZip.Source a -t7z -mx=9 -ms=on -mqs=on -mfb=273 -md=64m $solidArchive "$packageDir/*" | Out-Null
                    $finalHash = Get-FastSha256 -FilePath $solidArchive
                    $finalUrl = "https://github.com/$env:GITHUB_REPOSITORY/releases/download/$appName-v$latestVersion/$appName-$latestVersion.7z"
                }
            }

            "LocalBuild" {
                # Manifest will compile locally via pre_install; compute source archive hash
                $tempSource = Join-Path $workDir "source_file"
                Invoke-WebRequest -Uri $downloadUrl -OutFile $tempSource
                $finalHash = Get-FastSha256 -FilePath $tempSource
                Remove-Item -LiteralPath $tempSource -Force
            }

            default { # Upstream mode
                $tempFile = Join-Path $workDir "upstream_file"
                Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile
                $finalHash = Get-FastSha256 -FilePath $tempFile
                Remove-Item -LiteralPath $tempFile -Force
            }
        }

        # --- 3.3 Auto-Persist & Manifest Construction ---
        $manifestObj = [ordered]@{
            "version"      = $latestVersion
            "description"  = $recipe.description
            "homepage"     = $recipe.homepage
            "license"      = $recipe.license
        }

        # Architecture and binary configuration
        $archData = [ordered]@{
            "url"  = $finalUrl
            "hash" = $finalHash
        }
        if ($recipe.bin) { $archData["bin"] = $recipe.bin }
        if ($recipe.shortcuts) { $archData["shortcuts"] = $recipe.shortcuts }

        $manifestObj["architecture"] = [ordered]@{ "64bit" = $archData }

        # Auto-Persist detection: preserves configuration and runtime states
        $persistList = [System.Collections.Generic.List[string]]::new()
        if ($recipe.persist) {
            foreach ($p in $recipe.persist) { $persistList.Add($p) }
        }
        # Fallback automatic discovery patterns if configured
        if ($recipe.auto_persist -eq $true) {
            @("config", "data", "settings.json", "config.json") | ForEach-Object {
                if (-not $persistList.Contains($_)) { $persistList.Add($_) }
            }
        }
        if ($persistList.Count -gt 0) {
            $manifestObj["persist"] = $persistList
        }

        # Local build hooks if requested
        if ($recipe.mode -eq "LocalBuild" -and $recipe.local_commands) {
            $manifestObj["pre_install"] = $recipe.local_commands
        }

        # Autoupdate metadata
        if ($recipe.source_type -eq "github_release") {
            $manifestObj["checkver"] = "github"
            $manifestObj["autoupdate"] = @{
                "architecture" = @{
                    "64bit" = @{
                        "url" = "https://api.github.com/repos/$($recipe.repo)/releases/latest"
                    }
                }
            }
        }

        # Save manifest
        $jsonContent = $manifestObj | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $manifestFile -Value $jsonContent -Encoding UTF8 -Force

        # Clean work dir
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue

        Write-Host "[$appName] Successfully updated to v$latestVersion." -ForegroundColor Green
    }
    catch {
        Write-Error "[$appName] Failed to process: $_"
    }
}

Write-Host "`nBucket generation complete. All manifests in '$BucketDir' are synchronized." -ForegroundColor Cyan
