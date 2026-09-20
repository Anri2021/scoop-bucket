<#
.SYNOPSIS
  Declarative Configuration Engine for Scoop (similar to winget configure).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$Manifest = "$PSScriptRoot/../scoop.manifest.json",

    [switch]$UpdateBuckets
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 1. וידוא התקנת Scoop
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Host "[Scoop-Config] Scoop אינו מותקן. מתקין את Scoop..." -ForegroundColor Cyan
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    $env:SCOOP_ALLOW_ADMIN = 1
    Invoke-RestMethod -Uri "https://get.scoop.sh" | Invoke-Expression
}

# 2. טעינת המניפסט (קובץ מקומי או כתובת רשת)
$config = if ($Manifest -match '^https?://') {
    Invoke-RestMethod -Uri $Manifest
} elseif (Test-Path -LiteralPath $Manifest) {
    Get-Content -LiteralPath $Manifest -Raw -Encoding utf8 | ConvertFrom-Json
} else {
    throw "מניפסט התצורה לא אותר: $Manifest"
}

# 3. סנכרון באקטים (Buckets)
$installedBuckets = @(scoop bucket list | ForEach-Object { ($_ -split '\s+')[0] })
if ($config.PSObject.Properties['buckets'] -and $config.buckets) {
    foreach ($b in $config.buckets) {
        $bName = if ($b -is [string]) { $b } else { $b.name }
        $bSource = if ($b -is [string]) { $null } else { $b.source }

        if ($bName -notin $installedBuckets) {
            Write-Host "[Scoop-Config] מוסיף באקט: $bName..." -ForegroundColor Cyan
            if ($bSource) { scoop bucket add $bName $bSource 2>$null } else { scoop bucket add $bName 2>$null }
        }
    }
}

if ($UpdateBuckets) {
    Write-Host "[Scoop-Config] מעדכן את מאגרי הבאקטים..." -ForegroundColor Cyan
    scoop update
}

# 4. החלת הגדרות תצורה (scoop config)
if ($config.PSObject.Properties['config'] -and $config.config) {
    foreach ($prop in $config.config.PSObject.Properties) {
        Write-Host "[Scoop-Config] מגדיר תצורה: $($prop.Name) = $($prop.Value)..." -ForegroundColor DarkCyan
        scoop config $prop.Name $prop.Value | Out-Null
    }
}

# 5. זיהוי חבילות והתקנת החסרות בלבד
$installedApps = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
@(scoop list | ForEach-Object { ($_ -split '\s+')[0] }) | ForEach-Object { $null = $installedApps.Add($_) }

$missingApps = [System.Collections.Generic.List[string]]::new()
if ($config.PSObject.Properties['apps'] -and $config.apps) {
    foreach ($app in $config.apps) {
        $cleanName = ($app -split '/')[-1]
        if (-not $installedApps.Contains($cleanName)) {
            $missingApps.Add($app)
        }
    }
}

if ($missingApps.Count -gt 0) {
    Write-Host "[Scoop-Config] מתקין $($missingApps.Count) חבילות חסרות..." -ForegroundColor Yellow
    scoop install @($missingApps)
    scoop cache rm *
    Write-Host "[Scoop-Config] כל החבילות הותקנו בהצלחה." -ForegroundColor Green
} else {
    Write-Host "[Scoop-Config] המערכת מעודכנת. כל החבילות כבר מותקנות." -ForegroundColor Green
}
