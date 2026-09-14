<#
.SYNOPSIS
  Deterministic, parallel Meta-Bucket engine for PowerShell 7+.
.DESCRIPTION
  recipes.json is the only hand-edited source of truth. Work inside a tier runs in
  parallel; tiers run in order so cached bootstrap tools are available downstream.
#>
[CmdletBinding()]
param(
  [string]$RecipesPath = "$PSScriptRoot/../recipes.json",
  [string]$BucketDir = "$PSScriptRoot/../bucket",
  [string]$BuildDir = "$PSScriptRoot/../dist",
  [ValidateRange(1, 32)][int]$ThrottleLimit = [Math]::Min([Environment]::ProcessorCount, 8),
  [switch]$ForceRebuild,
  [switch]$ValidateOnly,
  [switch]$NoPublish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Get-PropertyValue {
  param([object]$Object, [string]$Name, $Default = $null)
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $Default }
  return $property.Value
}

if (-not (Test-Path -LiteralPath $RecipesPath -PathType Leaf)) {
  throw "Recipes file not found: $RecipesPath"
}

$RecipesPath = [IO.Path]::GetFullPath($RecipesPath)
$BucketDir = [IO.Path]::GetFullPath($BucketDir)
$BuildDir = [IO.Path]::GetFullPath($BuildDir)
$configuration = Get-Content -LiteralPath $RecipesPath -Raw -Encoding utf8 | ConvertFrom-Json
$recipes = @($configuration.recipes)

if ($recipes.Count -eq 0) { throw "recipes.json contains no recipes." }

$allowedModes = [Collections.Generic.HashSet[string]]::new(
  [string[]]@("auto", "upstream", "cloud", "local", "hybrid"),
  [StringComparer]::OrdinalIgnoreCase
)
$names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($recipe in $recipes) {
  $name = [string](Get-PropertyValue $recipe "name")
  $repo = [string](Get-PropertyValue $recipe "repo")
  $mode = [string](Get-PropertyValue $recipe "mode" "auto")
  if ([string]::IsNullOrWhiteSpace($name)) { throw "Every recipe requires a name." }
  if (-not $names.Add($name)) { throw "Duplicate recipe name: $name" }
  if ([string]::IsNullOrWhiteSpace($repo)) { throw "Recipe '$name' requires repo." }
  if (-not $allowedModes.Contains($mode)) { throw "Recipe '$name' has unsupported mode '$mode'." }
}

$null = New-Item -ItemType Directory -Force -Path $BuildDir
if (-not $ValidateOnly) { $null = New-Item -ItemType Directory -Force -Path $BucketDir }

$targetRepository = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { "Anri2021/scoop-bucket" }
$tiers = @($recipes | ForEach-Object { [int](Get-PropertyValue $_ "tier" 1) } | Sort-Object -Unique)
$allResults = [Collections.Generic.List[object]]::new()

foreach ($tier in $tiers) {
  $tierRecipes = @($recipes | Where-Object { [int](Get-PropertyValue $_ "tier" 1) -eq $tier })
  Write-Host "Tier ${tier}: resolving $($tierRecipes.Count) recipe(s), throttle $ThrottleLimit."

  $tierResults = @($tierRecipes | ForEach-Object -Parallel {
    $recipe = $_
    $buildRoot = $using:BuildDir
    $bucketRoot = $using:BucketDir
    $targetRepo = $using:targetRepository
    $force = $using:ForceRebuild
    $validate = $using:ValidateOnly
    $noPublish = $using:NoPublish

    function Prop {
      param([object]$Object, [string]$Name, $Default = $null)
      $property = $Object.PSObject.Properties[$Name]
      if ($null -eq $property -or $null -eq $property.Value) { return $Default }
      return $property.Value
    }

    function Invoke-Checked {
      param([string]$File, [string[]]$Arguments)
      & $File @Arguments | Out-Host
      if ($LASTEXITCODE -ne 0) { throw "'$File' exited with code $LASTEXITCODE." }
    }

    function Get-Sha256 {
      param([string]$Path)
      $stream = [IO.File]::OpenRead($Path)
      try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
      finally { $stream.Dispose() }
    }

    function Get-CachedFile {
      param([string]$Url, [string]$Path, [string]$ExpectedHash)
      if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if (-not $ExpectedHash -or (Get-Sha256 $Path) -eq $ExpectedHash) { return $Path }
        Remove-Item -LiteralPath $Path -Force
      }
      $null = New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($Path))
      Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
      $actual = Get-Sha256 $Path
      if ($ExpectedHash -and $actual -ne $ExpectedHash) {
        Remove-Item -LiteralPath $Path -Force
        throw "SHA256 mismatch for $Url"
      }
      return $Path
    }

    function AssetHash {
      param([object]$Asset, [string]$CacheRoot)
      $digest = [string](Prop $Asset "digest" "")
      if ($digest -match "^sha256:(?<hash>[a-fA-F0-9]{64})$") { return $Matches.hash.ToLowerInvariant() }
      $file = Join-Path $CacheRoot ([string]$Asset.id + "-" + [string]$Asset.name)
      $null = Get-CachedFile ([string]$Asset.browser_download_url) $file ""
      return Get-Sha256 $file
    }

    $name = [string](Prop $recipe "name")
    $mode = ([string](Prop $recipe "mode" "auto")).ToLowerInvariant()
    $workDir = Join-Path $buildRoot ("work\" + $name)
    $cacheDir = Join-Path $buildRoot "cache"
    try {
      $headers = @{ Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28" }
      $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
      if ($token) { $headers.Authorization = "Bearer $token" }

      $release = Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/releases/latest" -f $recipe.repo) -Headers $headers
      $versionPattern = [string](Prop $recipe "version_regex" "(?<version>\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.-]+)?)")
      $match = [regex]::Match([string]$release.tag_name, $versionPattern)
      if (-not $match.Success) { throw "Tag '$($release.tag_name)' does not match version_regex." }
      $version = if ($match.Groups["version"].Success) { $match.Groups["version"].Value } else { $match.Value }

      $assetPattern = [string](Prop $recipe "asset_pattern" "")
      $primary = $null
      if ($assetPattern) { $primary = @($release.assets | Where-Object { $_.name -match $assetPattern }) | Select-Object -First 1 }

      if ($mode -eq "auto") { $mode = if ($primary) { "upstream" } else { "cloud" } }
      if ($mode -eq "upstream" -and -not $primary) { throw "No upstream asset matches '$assetPattern'." }

      $manifestPath = Join-Path $bucketRoot "$name.json"
      $currentVersion = $null
      if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $currentVersion = (Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json).version
      }

      if ($validate) {
        return [pscustomobject]@{ Name=$name; Version=$version; Mode=$mode; Status="validated"; Manifest=$null; Lock=$null; BootstrapPath=$null; Error=$null }
      }

      $urls = [Collections.Generic.List[string]]::new()
      $hashes = [Collections.Generic.List[string]]::new()
      $persist = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
      foreach ($item in @(Prop $recipe "persist" @())) { $null = $persist.Add([string]$item) }
      $bootstrapPath = $null

      if ($mode -eq "upstream") {
        $assets = [Collections.Generic.List[object]]::new()
        $assets.Add($primary)
        foreach ($pattern in @(Prop $recipe "extra_assets" @())) {
          $extra = @($release.assets | Where-Object { $_.name -match [string]$pattern }) | Select-Object -First 1
          if (-not $extra) { throw "No extra asset matches '$pattern'." }
          $assets.Add($extra)
        }
        foreach ($asset in $assets) {
          $urls.Add([string]$asset.browser_download_url)
          $hashes.Add((AssetHash $asset $cacheDir))
          if ($asset.name -match "(?i)(^|[._-])(config|settings).*\.(conf|ini|json|ya?ml)$") { $null = $persist.Add([string]$asset.name) }
        }

        if ([bool](Prop $recipe "bootstrap" $false)) {
          $toolRoot = Join-Path $buildRoot ("toolchain\" + $name + "\" + $version)
          $marker = Join-Path $toolRoot ".complete"
          if (-not (Test-Path -LiteralPath $marker)) {
            $null = New-Item -ItemType Directory -Force -Path $toolRoot
            $archive = Join-Path $cacheDir ([string]$primary.id + "-" + [string]$primary.name)
            $null = Get-CachedFile ([string]$primary.browser_download_url) $archive $hashes[0]
            if ($primary.name -match "\.zip$") { Expand-Archive -LiteralPath $archive -DestinationPath $toolRoot -Force }
            elseif ($primary.name -match "\.7z$") { Invoke-Checked "7z" @("x", "-y", "-o$toolRoot", $archive) }
            else { Copy-Item -LiteralPath $archive -Destination $toolRoot -Force }
            Set-Content -LiteralPath $marker -Value $version -Encoding ascii
          }
          $bootstrapExe = [string](Prop $recipe "bootstrap_exe" (Prop $recipe "bin"))
          $found = Get-ChildItem -LiteralPath $toolRoot -Filter $bootstrapExe -File -Recurse | Select-Object -First 1
          if (-not $found) { throw "Bootstrap executable '$bootstrapExe' was not found." }
          $bootstrapPath = $found.DirectoryName
        }
      }
      elseif ($mode -in @("cloud", "hybrid")) {
        $tag = "$name-v$version"
        $archiveName = "$name-$version-windows-x64.7z"
        $published = $null
        try {
          $ownRelease = Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/releases/tags/{1}" -f $targetRepo, $tag) -Headers $headers
          $published = @($ownRelease.assets | Where-Object { $_.name -eq $archiveName }) | Select-Object -First 1
        } catch {
          if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw }
        }

        if ($noPublish) { $published = $null }

        if (-not $published) {
          Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
          $sourceDir = Join-Path $workDir "source"
          $packageDir = Join-Path $workDir "package"
          $null = New-Item -ItemType Directory -Force -Path $sourceDir, $packageDir
          $sourceZip = Join-Path $cacheDir ("source-" + $release.id + ".zip")
          $null = Get-CachedFile ([string]$release.zipball_url) $sourceZip ""
          Expand-Archive -LiteralPath $sourceZip -DestinationPath $sourceDir -Force
          $sourceRoot = (Get-ChildItem -LiteralPath $sourceDir -Directory | Select-Object -First 1).FullName
          $buildType = ([string](Prop $recipe "build_type" "auto")).ToLowerInvariant()
          if ($buildType -eq "auto") {
            $buildType = if (Test-Path (Join-Path $sourceRoot "pyproject.toml")) { "python" }
              elseif (Test-Path (Join-Path $sourceRoot "package.json")) { "node" }
              elseif (Test-Path (Join-Path $sourceRoot "Cargo.toml")) { "rust" }
              elseif (Test-Path (Join-Path $sourceRoot "go.mod")) { "go" }
              else { "powershell" }
          }

          Push-Location $sourceRoot
          try {
            switch ($buildType) {
              "python" {
                $entry = [string](Prop $recipe "entrypoint" "")
                if (-not $entry) { $entry = (Get-ChildItem -LiteralPath $sourceRoot -Filter "*.py" -File | Select-Object -First 1).Name }
                if (-not $entry) { throw "Python entrypoint not found." }
                $requirements = Join-Path $sourceRoot "requirements.txt"
                if (Test-Path $requirements) { Invoke-Checked "python" @("-m","pip","install","--disable-pip-version-check","-r",$requirements) }
                Invoke-Checked "python" @("-m","PyInstaller","--noconfirm","--clean","--onefile","--name",$name,"--distpath",$packageDir,$entry)
              }
              "go" {
                Invoke-Checked "go" @("build","-trimpath","-ldflags=-s -w","-o",(Join-Path $packageDir "$name.exe"),".")
              }
              "rust" {
                Invoke-Checked "cargo" @("build","--locked","--release")
                Get-ChildItem -LiteralPath (Join-Path $sourceRoot "target\release") -Filter "*.exe" -File | Copy-Item -Destination $packageDir
              }
              "node" {
                Invoke-Checked "corepack" @("enable")
                Invoke-Checked "pnpm" @("install","--frozen-lockfile")
                Invoke-Checked "pnpm" @("run","build")
                foreach ($path in @("build","drizzle","package.json","pnpm-lock.yaml")) {
                  $candidate = Join-Path $sourceRoot $path
                  if (Test-Path $candidate) { Copy-Item -LiteralPath $candidate -Destination $packageDir -Recurse -Force }
                }
                Push-Location $packageDir
                try { Invoke-Checked "pnpm" @("install","--prod","--frozen-lockfile") } finally { Pop-Location }
                @("@echo off",'node "%~dp0build\server\index.js" %*') | Set-Content -LiteralPath (Join-Path $packageDir "$name.cmd") -Encoding ascii
              }
              "powershell" {
                $entry = [string](Prop $recipe "entrypoint" (Prop $recipe "bin"))
                $candidate = Join-Path $sourceRoot $entry
                if (-not (Test-Path $candidate)) { throw "PowerShell entrypoint '$entry' not found." }
                Copy-Item -LiteralPath $candidate -Destination $packageDir
              }
              default { throw "Unsupported build_type '$buildType'." }
            }
          } finally { Pop-Location }

          Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Include "*.conf","*.ini","config.json","*.yaml","*.yml" |
            ForEach-Object {
              Copy-Item -LiteralPath $_.FullName -Destination $packageDir -Force
              $null = $persist.Add($_.Name)
            }
          Get-ChildItem -LiteralPath $packageDir -Recurse -Force |
            Where-Object { $_.Name -match "(?i)^(test|tests|docs|__pycache__)$|\.(map|pdb|d\.ts|pyc)$" } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
          if (-not (Get-ChildItem -LiteralPath $packageDir -File -Recurse | Select-Object -First 1)) { throw "Build produced no package files." }

          $archive = Join-Path $workDir $archiveName
          Invoke-Checked "7z" @("a","-t7z","-mx=9","-m0=lzma2","-ms=on","-mqs=on","-mmt=on",$archive,(Join-Path $packageDir "*"))
          $assetHash = Get-Sha256 $archive
          if ($noPublish) {
            $urls.Add($archive)
          } else {
            $existingRelease = $false
            try { $null = Invoke-Checked "gh" @("release","view",$tag,"--repo",$targetRepo); $existingRelease = $true } catch {}
            if ($existingRelease) { Invoke-Checked "gh" @("release","upload",$tag,$archive,"--repo",$targetRepo,"--clobber") }
            else { Invoke-Checked "gh" @("release","create",$tag,$archive,"--repo",$targetRepo,"--title","$name $version","--notes","Automated Meta-Bucket build.") }
            $urls.Add("https://github.com/$targetRepo/releases/download/$tag/$archiveName")
          }
          $hashes.Add($assetHash)
        } else {
          $urls.Add([string]$published.browser_download_url)
          $hashes.Add((AssetHash $published $cacheDir))
        }
      }
      elseif ($mode -eq "local") {
        $sourceUrl = [string]$release.zipball_url
        $sourceFile = Join-Path $cacheDir ("source-" + $release.id + ".zip")
        $null = Get-CachedFile $sourceUrl $sourceFile ""
        $urls.Add($sourceUrl)
        $hashes.Add((Get-Sha256 $sourceFile))
      }

      $manifest = [ordered]@{
        version = $version
        description = [string](Prop $recipe "description")
        homepage = [string](Prop $recipe "homepage" ("https://github.com/" + [string]$recipe.repo))
        license = [string](Prop $recipe "license")
        url = if ($urls.Count -eq 1) { $urls[0] } else { @($urls) }
        hash = if ($hashes.Count -eq 1) { $hashes[0] } else { @($hashes) }
      }
      $extractDir = [string](Prop $recipe "extract_dir" "")
      if ($extractDir) { $manifest.extract_dir = $extractDir }
      $bin = Prop $recipe "bin"
      if ($bin) { $manifest.bin = $bin }
      $depends = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
      foreach ($dependency in @(Prop $recipe "depends" @())) { $null = $depends.Add([string]$dependency) }
      if ($mode -in @("local","hybrid")) {
        $defaultDependency = switch (([string](Prop $recipe "build_type" "")).ToLowerInvariant()) {
          "python" { "python" }; "go" { "go" }; "rust" { "rust" }; "node" { "nodejs-lts" }; "bun" { "bun" }; default { $null }
        }
        if ($defaultDependency) { $null = $depends.Add($defaultDependency) }
      }
      if ($depends.Count) { $manifest.depends = @($depends | Sort-Object) }
      $commands = @(Prop $recipe "local_commands" @())
      if ($mode -in @("local","hybrid") -and $commands.Count) { $manifest.pre_install = $commands }
      if ($persist.Count) { $manifest.persist = @($persist | Sort-Object) }
      if (Prop $recipe "shortcuts") { $manifest.shortcuts = Prop $recipe "shortcuts" }

      $status = if (-not $force -and $currentVersion -eq $version) { "verified" } else { "updated" }
      return [pscustomobject]@{
        Name=$name; Version=$version; Mode=$mode; Status=$status; Manifest=$manifest
        Lock=[ordered]@{ version=$version; tag=[string]$release.tag_name; mode=$mode; checked_at=[DateTime]::UtcNow.ToString("o") }
        BootstrapPath=$bootstrapPath; Error=$null
      }
    } catch {
      return [pscustomobject]@{ Name=$name; Version=$null; Mode=$mode; Status="failed"; Manifest=$null; Lock=$null; BootstrapPath=$null; Error=$_.Exception.Message }
    } finally {
      Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  } -ThrottleLimit $ThrottleLimit)

  foreach ($result in $tierResults) {
    $allResults.Add($result)
    if ($result.BootstrapPath) {
      $env:PATH = "$($result.BootstrapPath);$env:PATH"
      if ($env:GITHUB_PATH) { Add-Content -LiteralPath $env:GITHUB_PATH -Value $result.BootstrapPath }
    }
  }
}

$failures = @($allResults | Where-Object Error)
$allResults | Sort-Object Name | Format-Table Name, Version, Mode, Status -AutoSize
if ($failures.Count) {
  $details = $failures | ForEach-Object { "[$($_.Name)] $($_.Error)" }
  throw "Meta-Bucket failed:$([Environment]::NewLine)$($details -join [Environment]::NewLine)"
}
if ($ValidateOnly) {
  Write-Host "All recipes are valid and their latest releases are resolvable." -ForegroundColor Green
  exit 0
}

foreach ($result in $allResults | Sort-Object Name) {
  $path = Join-Path $BucketDir "$($result.Name).json"
  $json = $result.Manifest | ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText($path, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

$activeNames = [Collections.Generic.HashSet[string]]::new([string[]]$names, [StringComparer]::OrdinalIgnoreCase)
Get-ChildItem -LiteralPath $BucketDir -Filter "*.json" -File | Where-Object {
  -not $activeNames.Contains($_.BaseName)
} | Remove-Item -Force

$lock = [ordered]@{
  generated_at = [DateTime]::UtcNow.ToString("o")
  recipes_sha256 = (Get-FileHash -LiteralPath $RecipesPath -Algorithm SHA256).Hash.ToLowerInvariant()
  packages = [ordered]@{}
}
foreach ($result in $allResults | Sort-Object Name) { $lock.packages[$result.Name] = $result.Lock }
$lockPath = Join-Path ([IO.Path]::GetDirectoryName($RecipesPath)) "recipes.lock.json"
[IO.File]::WriteAllText($lockPath, (($lock | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
Write-Host "Generated $($allResults.Count) deterministic Scoop manifest(s)." -ForegroundColor Green
