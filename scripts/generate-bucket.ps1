[CmdletBinding()]
param(
    [string]$RecipesPath = "recipes.json",
    [string]$BucketDir   = "bucket"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $RecipesPath)) {
    throw "Recipes file not found at '$RecipesPath'"
}

if (-not (Test-Path $BucketDir)) {
    New-Item -ItemType Directory -Path $BucketDir -Force | Out-Null
}

$recipesData = Get-Content $RecipesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$recipes = $recipesData.recipes

Write-Host "Loaded $($recipes.Count) recipe(s) from $RecipesPath"

foreach ($recipe in $recipes) {
    $name       = $recipe.name
    $mode       = if ($recipe.mode) { $recipe.mode.ToLower() } else { "auto" }
    $sourceType = if ($recipe.source_type) { $recipe.source_type.ToLower() } else { "github" }

    Write-Host "`n==============================="
    Write-Host "Processing: $name (Mode: $mode, Source: $sourceType)"
    Write-Host "==============================="

    $version      = $null
    $downloadUrl  = $null
    $sha256       = $null
    $upstreamAssetFound = $false

    # -------------------------------------------------------------
    # 1. שליפת מידע וגרסאות מול המקור (GitHub או PyPI)
    # -------------------------------------------------------------
    if ($sourceType -eq "github") {
        $repo = $recipe.repo
        $release = gh api "repos/$repo/releases/latest" 2>$null | ConvertFrom-Json

        if (-not $release -or -not $release.tag_name) {
            Write-Warning "Could not fetch release for $repo. Skipping."
            continue
        }

        $version = $release.tag_name.TrimStart('v')
        Write-Host "Latest upstream release for $name is v$version"

        # בדיקת נכסים בינאריים מוכנים ל-Windows ב-Upstream
        $winAsset = $release.assets | Where-Object {
            $_.name -match "(\.zip|\.exe|\.msi)$" -and
            $_.name -match "(win|windows|x86_64|x64|amd64)"
        } | Select-Object -First 1

        if ($winAsset) {
            $upstreamAssetFound = $true
            $upstreamDownloadUrl = $winAsset.browser_download_url
            Write-Host "Found upstream Windows asset: $($winAsset.name)"
        }
    }
    elseif ($sourceType -eq "pypi") {
        $pkgName = $recipe.package_name
        $pypiMeta = Invoke-RestMethod -Uri "https://pypi.org/pypi/$pkgName/json"
        $version = $pypiMeta.info.version
        Write-Host "Latest PyPI version for $name is $version"

        # בדיקת קובץ Wheel מוכן ל-Windows x64
        $wheel = $pypiMeta.urls | Where-Object {
            $_.packagetype -eq "bdist_wheel" -and
            $_.filename -match "(win_amd64|any)"
        } | Select-Object -First 1

        if ($wheel) {
            $upstreamAssetFound = $true
            $upstreamDownloadUrl = $wheel.url
            $sha256 = $wheel.digests.sha256
            Write-Host "Found compatible PyPI wheel: $($wheel.filename)"
        }
    }

    # -------------------------------------------------------------
    # 2. החלטה על אסטרטגיית הבנייה וההורדה
    # -------------------------------------------------------------
    $targetManifestPath = Join-Path $BucketDir "$name.json"
    $currentManifest = if (Test-Path $targetManifestPath) {
        Get-Content $targetManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { $null }

    $isNewVersion = (-not $currentManifest) -or ($currentManifest.version -ne $version)

    # מצב Upstream מפורש או Auto שיש לו קובץ מוכן במקור
    if ($mode -eq "upstream" -or ($mode -eq "auto" -and $upstreamAssetFound)) {
        if (-not $upstreamAssetFound) {
            Write-Warning "Upstream asset requested but none found for $name. Skipping."
            continue
        }
        $downloadUrl = $upstreamDownloadUrl
        Write-Host "Using upstream pass-through for $name"
    }

    # מצב קימפול בענן (Cloud Build) עבור פרויקטים ללא קבצים בינאריים מוכנים
    elseif ($mode -eq "cloud" -or ($mode -eq "auto" -and -not $upstreamAssetFound)) {
        $myRepo = $env:GITHUB_REPOSITORY
        if (-not $myRepo) { $myRepo = "Anri2021/scoop-bucket" }

        $releaseTag = "$name-v$version"
        $zipName    = "$name-v$version-windows-x64.zip"
        $downloadUrl = "https://github.com/$myRepo/releases/download/$releaseTag/$zipName"

        $releaseExists = gh release view $releaseTag --repo $myRepo 2>$null

        if ($releaseExists -and -not $isNewVersion) {
            Write-Host "Release $releaseTag already exists in $myRepo. Skipping cloud compilation."
            continue
        }

        Write-Host "Starting Cloud Build for $name v$version..."
        $workDir = New-Item -ItemType Directory -Path "build_temp_$name" -Force

        # הורדת קוד המקור
        $sourceZip = Join-Path $workDir "source.zip"
        Invoke-WebRequest -Uri "https://github.com/$($recipe.repo)/archive/refs/tags/v$version.zip" -OutFile $sourceZip
        Expand-Archive -Path $sourceZip -DestinationPath "$workDir\src"
        $srcRoot = (Get-ChildItem -Directory "$workDir\src" | Select-Object -First 1).FullName

        Push-Location $srcRoot

        # זיהוי חתימות פרויקט ובנייה בענן
        if (Test-Path "package.json") {
            Write-Host "Detected Bun / Node.js project. Building..."
            bun install --ignore-scripts --no-progress
            bun run build
            bun install --production --ignore-scripts --no-progress
        }
        elseif (Test-Path "Cargo.toml") {
            Write-Host "Detected Rust project. Building..."
            cargo build --release
        }
        elseif (Test-Path "go.mod") {
            Write-Host "Detected Go project. Building..."
            go build -ldflags="-s -w" -o "$workDir\out\"
        }

        Pop-Location

        # אריזת התוצר הבינארי
        $distDir = New-Item -ItemType Directory -Path "$workDir\dist" -Force
        if (Test-Path "$srcRoot\build") {
            Copy-Item -Recurse "$srcRoot\build" "$distDir\build"
            Copy-Item -Recurse "$srcRoot\node_modules" "$distDir\node_modules"
            Copy-Item "$srcRoot\package.json" "$distDir\package.json"
            @('@echo off', 'node "%~dp0build\server\index.js" %*') | Set-Content -Path "$distDir\$($recipe.bin)" -Encoding ASCII
        }
        elseif (Test-Path "$srcRoot\target\release") {
            Get-ChildItem "$srcRoot\target\release\*.exe" | Copy-Item -Destination $distDir
        }
        elseif (Test-Path "$workDir\out") {
            Copy-Item "$workDir\out\*" -Destination $distDir
        }

        $packagedZip = Join-Path $workDir $zipName
        Compress-Archive -Path "$distDir\*" -DestinationPath $packagedZip -Force
        $sha256 = (Get-FileHash -Path $packagedZip -Algorithm SHA256).Hash.ToLower()

        # העלאת שחרור חדש ל-GitHub Releases
        Write-Host "Publishing release $releaseTag to $myRepo..."
        gh release create $releaseTag $packagedZip `
            --repo $myRepo `
            --title "$name v$version" `
            --notes "Automated generic cloud build for $name v$version"

        Remove-Item -Recurse -Force $workDir
    }

    # -------------------------------------------------------------
    # 3. יצירת/עדכון קובץ המניפסט הסופי בתיקיית bucket/
    # -------------------------------------------------------------
    $manifestObj = [ordered]@{
        "version"     = $version
        "description" = $recipe.description
        "homepage"    = $recipe.homepage
        "license"     = $recipe.license
    }

    if ($recipe.depends) {
        $manifestObj["depends"] = $recipe.depends
    }

    $manifestObj["url"] = $downloadUrl
    $manifestObj["hash"] = if ($sha256) { $sha256 } else { "skip" }
    $manifestObj["bin"] = $recipe.bin

    if ($mode -eq "cloud") {
        $manifestObj["checkver"] = @{
            "github" = "https://github.com/$($recipe.repo)"
        }
        $manifestObj["autoupdate"] = @{
            "url" = "https://github.com/Anri2021/scoop-bucket/releases/download/$name-v`$version/$name-v`$version-windows-x64.zip"
        }
    }
    elseif ($sourceType -eq "github") {
        $manifestObj["checkver"] = "github"
        $manifestObj["autoupdate"] = @{
            "url" = "https://github.com/$($recipe.repo)/releases/download/v`$version/" + [System.IO.Path]::GetFileName($downloadUrl)
        }
    }

    $manifestJson = $manifestObj | ConvertTo-Json -Depth 10
    Set-Content -Path $targetManifestPath -Value $manifestJson -Encoding UTF8
    Write-Host "Generated/Updated manifest: $targetManifestPath"
}
