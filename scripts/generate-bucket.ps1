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

# מיון לפי Tier: כלי הבסיס (Tier 0) ירוצו וייטענו ראשונים, ולאחריהם שאר היישומים (Tier 1)
$recipes = $recipes | Sort-Object { if ($null -ne $_.tier) { [int]$_.tier } else { 1 } }

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
    # איפוס משתני מצב בכל איטרציה למניעת זליגת הגדרות בין חבילות
    $localPreInstall = @()
    $injectedDepends = @()
    $distDir         = $null

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

        # בדיקת נכסים בינאריים או סקריפטים מוכנים ל-Windows ב-Upstream
        $winAsset = $release.assets | Where-Object {
            ($_.name -match "\.(exe|msi|ps1)$") -or
            ($_.name -match "\.zip$" -and ($_.name -match "(win|windows|x86_64|x64|amd64)" -or $release.assets.Count -eq 1))
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

        # בדיקת קובץ Wheel - עדיפות ראשונה ל-any (Pure Python אוניברסלי), עדיפות שנייה ל-win_amd64
        $wheel = ($pypiMeta.urls | Where-Object { $_.packagetype -eq "bdist_wheel" -and $_.filename -match "any\.whl$" } | Select-Object -First 1)
        if (-not $wheel) {
            $wheel = ($pypiMeta.urls | Where-Object { $_.packagetype -eq "bdist_wheel" -and $_.filename -match "win_amd64\.whl$" } | Select-Object -First 1)
        }

        if ($wheel) {
            $upstreamAssetFound = $true
            $upstreamDownloadUrl = $wheel.url
            $sha256 = $wheel.digests.sha256
            Write-Host "Found compatible PyPI wheel: $($wheel.filename)"
        }

        # אם אין גלגל מוכן (any או win_amd64) - בניית Wheel מקוד מקור (sdist)
        if (-not $wheel) {
            $sdist = $pypiMeta.urls | Where-Object { $_.packagetype -eq "sdist" } | Select-Object -First 1
            if ($sdist) {
                Write-Host "No pre-built wheel found. Building wheel from source distribution..."
                $tempPyDir = New-Item -ItemType Directory -Path "temp_py_$name" -Force
                pip wheel --no-deps $sdist.url --wheel-dir $tempPyDir
                $builtWheel = Get-ChildItem "$tempPyDir\*.whl" | Select-Object -First 1
                if ($builtWheel) {
                    $wheel = [PSCustomObject]@{
                        url = $builtWheel.FullName
                        filename = $builtWheel.Name
                        digests = @{ sha256 = (Get-FileHash $builtWheel.FullName -Algorithm SHA256).Hash.ToLower() }
                    }
                }
            }
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

    # מדרג החלטה אוטומטי מלא: Upstream -> Cloud -> Hybrid -> Local
    if ($mode -eq "auto") {
        if ($upstreamAssetFound) {
            $mode = "upstream"
        }
        elseif ($recipe.build_type -in @("bun", "node") -and (Test-Path "package.json")) {
            $mode = "hybrid" # הכנת ספריות ו-Frontend בענן, קימפול שרתי קצה מקומית
        }
        elseif ($recipe.build_type -in @("rust", "go", "c", "make")) {
            $mode = "local" # התאמה מלאה לחומרת המחשב המקומי
        }
        else {
            $mode = "cloud"
        }
    }

    # מצב Upstream מפורש או Auto שיש לו קובץ מוכן במקור
    if ($mode -eq "upstream" -or ($mode -eq "auto" -and $upstreamAssetFound)) {
        if (-not $upstreamAssetFound) {
            Write-Warning "Upstream asset requested but none found for $name. Skipping."
            continue
        }
        $downloadUrl = $upstreamDownloadUrl
        Write-Host "Using upstream pass-through for $name"

        # חישוב Hash מקובץ ה-Upstream (מונע כתיבת "skip" במניפסט)
        if (-not $sha256) {
            $tempAsset = Join-Path $env:TEMP ([System.IO.Path]::GetFileName($downloadUrl))
            Invoke-WebRequest -Uri $downloadUrl -OutFile $tempAsset
            $sha256 = (Get-FileHash -Path $tempAsset -Algorithm SHA256).Hash.ToLower()
            Remove-Item -Force $tempAsset
        }
        # אם מדובר בכלי בנייה (Tier 0) - חילוץ וטעינה מיידית ל-PATH של הריצה
    if ($recipe.tier -eq 0) {
        Write-Host "Bootstrapping toolchain component: $name to PATH..."
        $toolsDir = Join-Path $env:TEMP "toolchain\$name"
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null

        $toolZip = Join-Path $env:TEMP "$name-tool.zip"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $toolZip
        Expand-Archive -Path $toolZip -DestinationPath $toolsDir -Force
        Remove-Item -Force $toolZip

        # איתור תיקיית הבינארי והוספה ל-PATH הנוכחי ול-GitHub Actions PATH
        $binDir = (Get-ChildItem -Path $toolsDir -Filter $recipe.bin -Recurse | Select-Object -First 1).DirectoryName
        if ($binDir) {
            $env:PATH = "$binDir;$env:PATH"
            if ($env:GITHUB_PATH) {
                Add-Content -Path $env:GITHUB_PATH -Value $binDir
            }
            Write-Host "Successfully loaded $name into environment PATH ($binDir)"
        }
    }
    }

    # מצב קימפול בענן (Cloud Build) עבור פרויקטים ללא קבצים בינאריים מוכנים
    elseif ($mode -eq "cloud" -or ($mode -eq "auto" -and -not $upstreamAssetFound)) {
        $myRepo = $env:GITHUB_REPOSITORY
        if (-not $myRepo) { $myRepo = "Anri2021/scoop-bucket" }

        $releaseTag = "$name-v$version"
        $zipName    = "$name-v$version-windows-x64.7z"
        $downloadUrl = "https://github.com/$myRepo/releases/download/$releaseTag/$zipName"

        # בדיקה מדויקת האם קובץ ה-7z הספציפי כבר קיים בתוך ה-Release
        $releaseJson = gh release view $releaseTag --repo $myRepo --json assets 2>$null | ConvertFrom-Json
        $assetExists = $releaseJson -and ($releaseJson.assets | Where-Object { $_.name -eq $zipName })

        if ($assetExists -and -not $isNewVersion) {
            Write-Host "Asset $zipName already exists in $releaseTag. Syncing asset hash..."
            $tempCheck = Join-Path $env:TEMP "$zipName"
            gh release download $releaseTag --repo $myRepo -p $zipName -O $tempCheck --clobber
            $sha256 = (Get-FileHash -Path $tempCheck -Algorithm SHA256).Hash.ToLower()
            Remove-Item -Force $tempCheck
        }
        else {
            Write-Host "Starting Cloud Build for $name v$version (packaging into $zipName)..."
        
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
        elseif (Test-Path "*.py") {
            Write-Host "Detected Python project. Compiling to standalone EXE with PyInstaller..."
            pip install --quiet pyinstaller
            $pyEntry = (Get-ChildItem "*.py" | Select-Object -First 1).Name
            pyinstaller --onefile --clean $pyEntry --distpath "$workDir\out"
        }
        elseif (Test-Path "*.ps1") {
            Write-Host "Detected standalone PowerShell utility. Copying scripts..."
            Copy-Item "*.ps1" -Destination "$workDir\out"
        }

        Pop-Location

        # אריזת התוצר הבינארי
        $distDir = New-Item -ItemType Directory -Path "$workDir\dist" -Force
        if ((Test-Path "$srcRoot\build") -and (Test-Path "$srcRoot\package.json")) {
            Copy-Item -Recurse "$srcRoot\build" "$distDir\build"
            Copy-Item -Recurse "$srcRoot\node_modules" "$distDir\node_modules"
            Copy-Item "$srcRoot\package.json" "$distDir\package.json"
            @('@echo off', 'node "%~dp0build\server\index.js" %*') | Set-Content -Path "$distDir\$($recipe.bin)" -Encoding ASCII
        }
        elseif (Test-Path "$srcRoot\target\release") {
            Get-ChildItem "$srcRoot\target\release\*.exe" | Copy-Item -Destination $distDir
        }
        if (Test-Path "$workDir\out") {
            Copy-Item "$workDir\out\*" -Destination $distDir
        }

        # העתקה אוטומטית של קובצי קונפיגורציה
        Get-ChildItem -Path $srcRoot -Include "*.conf", "*.ini", "config.json" -Recurse | Copy-Item -Destination $distDir -Force

        # ניקוי קובצי סרק מיותרים (sourcemaps, בדיקות וטיפוסים) להורדת הנפח
        Get-ChildItem -Path $distDir -Include "*.map", "*.d.ts", "*.md", "test", "tests" -Recurse | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        # בדיקת ביטחון לווידוא קיום קבצים
        $distFiles = Get-ChildItem -Path $distDir
        if (-not $distFiles) {
            throw "Build failed: No output binaries or scripts found in $distDir for $name."
        }

        # אריזה יעילה ומהירה ב-7z במקום ZIP פשוט
        $packagedZip = Join-Path $workDir $zipName
        7z a -t7z -mx=9 -ms=on "$packagedZip" "$distDir\*" | Out-Null
        $sha256 = (Get-FileHash -Path $packagedZip -Algorithm SHA256).Hash.ToLower()

        # העלאת שחרור חדש ל-GitHub Releases
        Write-Host "Publishing release $releaseTag to $myRepo..."
        # אם ה-Release כבר קיים - דריסת הקובץ הישן; אם לא - יצירת שחרור חדש
        if ($releaseExists) {
            Write-Host "Release $releaseTag already exists. Updating binary asset with --clobber..."
            gh release upload $releaseTag $packagedZip --repo $myRepo --clobber
        } else {
            Write-Host "Publishing new release $releaseTag to $myRepo..."
            gh release create $releaseTag $packagedZip `
                --repo $myRepo `
                --title "$name v$version" `
                --notes "Automated generic cloud build for $name v$version"
        }

        Remove-Item -Recurse -Force $workDir
        }
    }

    # מצב היברידי: הכנת תלויות ונכסים גנריים בענן, והשלמת קימפול מקומית
    elseif ($mode -eq "hybrid") {
        Write-Host "Executing Hybrid strategy for $name (Cloud preparation + Local completion)..."
        
        # 1. בענן: אריזת תלויות כבדות (כגון מודולים ונכסי Frontend שנבנו) לקובץ בסיס
        $myRepo = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { "Anri2021/scoop-bucket" }
        $releaseTag = "$name-v$version-hybrid"
        $zipName    = "$name-v$version-hybrid.zip"
        $downloadUrl = "https://github.com/$myRepo/releases/download/$releaseTag/$zipName"

        # 2. הזרקת פקודות קימפול משלימות לתוך Scoop בצד הלקוח
        $localPreInstall = @()
        $injectedDepends = @()
        if ($recipe.build_type -in @("node", "bun")) {
            $injectedDepends += "bun"
            $localPreInstall += "bun run build:native" # קימפול מקומי של מודולי מערכת בלבד
        }
        if ($recipe.custom_local_build) {
            $localPreInstall += $recipe.custom_local_build
        }
    }

    # מצב קימפול מקומי - הכנת הוראות בנייה ישירות לתוך המניפסט של Scoop
    elseif ($mode -eq "local") {
        Write-Host "Generating local build instructions for $name..."
        $downloadUrl = "https://github.com/$($recipe.repo)/archive/refs/tags/v$version.zip"
        # הורדה זמנית של קובץ המקור לחישוב Hash אמיתי (Scoop אינו תומך במחרוזת "skip")
        $tempSourceZip = Join-Path $env:TEMP "$name-v$version.zip"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempSourceZip
        $sha256 = (Get-FileHash -Path $tempSourceZip -Algorithm SHA256).Hash.ToLower()
        Remove-Item -Force $tempSourceZip

        $localPreInstall = @()
        $injectedDepends = @()

        # זיהוי כלי הבנייה הנדרשים והזרקתם לפי סוג הפרויקט
        if ($recipe.build_type -eq "node" -or $recipe.build_type -eq "bun") {
            $injectedDepends += "bun"
            $localPreInstall += "bun install --ignore-scripts --no-progress"
            $localPreInstall += "bun run build"
        }
        elseif ($recipe.build_type -eq "rust") {
            $injectedDepends += "rust"
            $localPreInstall += "cargo build --release"
        }
        elseif ($recipe.build_type -eq "go") {
            $injectedDepends += "go"
            $localPreInstall += 'go build -ldflags="-s -w"'
        }
        elseif ($recipe.build_type -eq "c" -or $recipe.build_type -eq "make") {
            $injectedDepends += "w64devkit"
            $localPreInstall += "make -j$env:NUMBER_OF_PROCESSORS"
        }

        # הוספת פקודות קימפול מותאמות אישית אם הוגדרו ב-recipe
        if ($recipe.custom_build) {
            $localPreInstall += $recipe.custom_build
        }
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

    # שילוב תלויות החבילה המקוריות עם כלי הבנייה שהוזרקו
    $finalDepends = @()
    if ($recipe.depends) { $finalDepends += $recipe.depends }
    if ($injectedDepends) { $finalDepends += $injectedDepends }
    if ($finalDepends.Count -gt 0) {
        $manifestObj["depends"] = if ($finalDepends.Count -eq 1) { $finalDepends[0] } else { $finalDepends | Select-Object -Unique }
    }

    # הזרקת סקריפט הבנייה המקומי ישירות לשדה pre_install במניפסט
    if ($localPreInstall -and $localPreInstall.Count -gt 0) {
        $manifestObj["pre_install"] = $localPreInstall
    }

    $manifestObj["url"] = $downloadUrl
    $manifestObj["hash"] = if ($sha256) { $sha256 } else { "skip" }
    $manifestObj["bin"] = $recipe.bin

    if ($mode -eq "cloud") {
        $manifestObj["checkver"] = @{
            "github" = "https://github.com/$($recipe.repo)"
        }
        $manifestObj["autoupdate"] = @{
            "url" = "https://github.com/Anri2021/scoop-bucket/releases/download/$name-v`$version/$name-v`$version-windows-x64.7z"
        }
    }
    elseif ($sourceType -eq "github") {
        $manifestObj["checkver"] = "github"
        $manifestObj["autoupdate"] = @{
            "url" = "https://github.com/$($recipe.repo)/releases/download/v`$version/" + [System.IO.Path]::GetFileName($downloadUrl)
        }
    }
    # זיהוי קובצי conf והגדרתם תחת persist כדי למנוע דריסת הגדרות בעדכון
    if ($distDir -and (Test-Path $distDir)) {
        $confFiles = @(Get-ChildItem -Path $distDir -Filter "*.conf" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        if ($confFiles.Count -gt 0) {
            $manifestObj["persist"] = if ($confFiles.Count -eq 1) { $confFiles[0] } else { $confFiles }
        }
    }

    $manifestJson = $manifestObj | ConvertTo-Json -Depth 10
    Set-Content -Path $targetManifestPath -Value $manifestJson -Encoding UTF8
    Write-Host "Generated/Updated manifest: $targetManifestPath"
}
