<#
.SYNOPSIS
  Meta-Bucket v4: deterministic planner, distributed builder and transactional finalizer.
#>
[CmdletBinding()]
param(
  [ValidateSet("Plan","Build","Finalize","All")][string]$Phase = "All",
  [string]$RecipesPath = "$PSScriptRoot/../recipes.json",
  [string]$PlanPath = "$PSScriptRoot/../dist/plan.json",
  [string]$StageDir = "$PSScriptRoot/../dist/stage",
  [string]$BucketDir = "$PSScriptRoot/../bucket",
  [string]$CacheDir = "$PSScriptRoot/../dist/cache",
  [string]$BuildEnvironmentPath = "$PSScriptRoot/../build-environment.json",
  [string]$PackageName = "",
  [ValidateRange(1,32)][int]$ThrottleLimit = [Math]::Min([Environment]::ProcessorCount, 8),
  [switch]$ForceRebuild,
  [switch]$NoPublish,
  [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$PSNativeCommandUseErrorActionPreference = $false

$EnginePath = [IO.Path]::GetFullPath($PSCommandPath)
$EngineDir = [IO.Path]::GetDirectoryName($EnginePath)

$CommonPath = Join-Path $EngineDir "core/Common.ps1"
if (-not (Test-Path -LiteralPath $CommonPath)) { throw "Common library not found: $CommonPath" }
. $CommonPath

$BuildersDir = Join-Path $EngineDir "builders"

$EngineVersion = "4.0"
$EngineSha256 = (Get-FileSha256 $EnginePath).ToLowerInvariant()
$BuildEnvironmentPath = [IO.Path]::GetFullPath($BuildEnvironmentPath)
if (-not (Test-Path -LiteralPath $BuildEnvironmentPath)) { throw "Build environment file not found: $BuildEnvironmentPath" }
$BuildEnvironment = Get-Content -LiteralPath $BuildEnvironmentPath -Raw -Encoding utf8 | ConvertFrom-Json
$BuildEnvironmentSha256 = (Get-FileSha256 $BuildEnvironmentPath).ToLowerInvariant()
$PipelineBytes = [Text.Encoding]::UTF8.GetBytes("$EngineSha256`n$BuildEnvironmentSha256")
$PipelineSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($PipelineBytes)).ToLowerInvariant()

function Get-Headers {
  $headers = @{ Accept="application/vnd.github+json"; "X-GitHub-Api-Version"="2022-11-28" }
  $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
  if ($token) { $headers.Authorization = "Bearer $token" }
  return $headers
}

function Get-DependencyLevels {
  param([object[]]$Items)
  $byName = @{}
  foreach ($item in $Items) { $byName[[string]$item.name] = $item }
  $remaining = [Collections.Generic.HashSet[string]]::new([string[]]$byName.Keys, [StringComparer]::OrdinalIgnoreCase)
  $done = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $levels = [Collections.Generic.List[object]]::new()
  while ($remaining.Count) {
    $ready = [Collections.Generic.List[string]]::new()
    foreach ($name in @($remaining | Sort-Object)) {
      $dependencies = @((Get-Prop $byName[$name] "tool_dependencies" @()) | ForEach-Object { [string]$_ })
      foreach ($dependency in $dependencies) {
        if (-not $byName.ContainsKey($dependency)) { throw "Recipe '$name' references missing tool_dependency '$dependency'." }
      }
      if (@($dependencies | Where-Object { -not $done.Contains($_) }).Count -eq 0) { $ready.Add($name) }
    }
    if ($ready.Count -eq 0) { throw "Circular tool_dependencies detected: $($remaining -join ', ')" }
    $levels.Add(@($ready))
    foreach ($name in $ready) { $null = $remaining.Remove($name); $null = $done.Add($name) }
  }
  return @($levels)
}

function Assert-Recipes {
  param([object[]]$Recipes)
  if ($Recipes.Count -eq 0) { throw "recipes.json contains no recipes." }
  $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($recipe in $Recipes) {
    $name = [string](Get-Prop $recipe "name")
    $mode = ([string](Get-Prop $recipe "mode" "auto")).ToLowerInvariant()
    $source = ([string](Get-Prop $recipe "source_type" "github")).ToLowerInvariant()
    $policy = ([string](Get-Prop $recipe "platform_policy" "universal-first")).ToLowerInvariant()
    if (-not $name) { throw "Every recipe requires name." }
    if (-not $names.Add($name)) { throw "Duplicate recipe '$name'." }
    if ($mode -notin @("auto","upstream","cloud","hybrid","local")) { throw "Recipe '$name' has invalid mode '$mode'." }
    if ($source -notin @("github","pypi")) { throw "Recipe '$name' has invalid source_type '$source'." }
    if ($source -eq "github" -and -not (Get-Prop $recipe "repo")) { throw "GitHub recipe '$name' requires repo." }
    if ($policy -notin @("universal-first","native-first","force-local")) { throw "Recipe '$name' has invalid platform_policy '$policy'." }
    foreach ($arch in @(Get-Prop $recipe "architectures" @("64bit"))) {
      if ([string]$arch -notin @("64bit","arm64")) { throw "Recipe '$name' has unsupported architecture '$arch'." }
    }
  }
  $null = Get-DependencyLevels $Recipes
}

function Resolve-Plans {
  param([object[]]$Recipes, [string]$TargetRepository, [string]$Engine, [string]$EngineHash, [switch]$Force)
  $headers = Get-Headers
  $cacheRoot = [IO.Path]::GetFullPath($CacheDir)
  $commonPath = $CommonPath
  $buildersDir = $BuildersDir

  $results = @($Recipes | ForEach-Object -Parallel {
    $recipe = $_
    $headers = $using:headers
    $cacheRoot = $using:cacheRoot
    $targetRepo = $using:TargetRepository
    $engine = $using:Engine
    $force = $using:Force
    $buildersDir = $using:buildersDir

    . $using:commonPath

    function AssetHash {
      param([object]$a, [string]$cRoot)
      $d = [string](Get-Prop $a "digest" "")
      if ($d -match "^sha256:(?<h>[a-fA-F0-9]{64})$") { return $Matches.h.ToLowerInvariant() }
      $p = Join-Path $cRoot ("asset-" + [string]$a.id + "-" + [string]$a.name)
      $null = Get-CachedFile ([string]$a.browser_download_url) $p
      return (Get-FileSha256 $p)
    }

    $name = [string](Get-Prop $recipe "name")
    try {
      $sourceType = ([string](Get-Prop $recipe "source_type" "github")).ToLowerInvariant()
      if ($sourceType -eq "pypi") {
        $package = [string](Get-Prop $recipe "package" $name)
        $metadata = Invoke-RestMethod ("https://pypi.org/pypi/{0}/json" -f $package)
        $version = [string]$metadata.info.version
        $assets = @($metadata.urls | ForEach-Object { [pscustomobject]@{id=$_.digests.sha256.Substring(0,16); name=$_.filename; browser_download_url=$_.url; digest="sha256:$($_.digests.sha256)"; packagetype=$_.packagetype} })
        $sdist = @($assets | Where-Object packagetype -eq "sdist") | Select-Object -First 1
        if (-not $sdist) { throw "No PyPI sdist." }
        $tag = $version; $sourceUrl = [string]$sdist.browser_download_url; $sourceHash = AssetHash $sdist $cacheRoot
        $sourceExtract = ([string]$sdist.name) -replace "(?i)(\.tar\.gz|\.tar\.bz2|\.zip)$", ""
      } else {
        $repo = [string](Get-Prop $recipe "repo")
        $release = Invoke-RestMethod ("https://api.github.com/repos/{0}/releases/latest" -f $repo) -Headers $headers
        $tag = [string]$release.tag_name
        $pattern = [string](Get-Prop $recipe "version_regex" "(?<version>\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.-]+)?)")
        $m = [regex]::Match($tag, $pattern); if (-not $m.Success) { throw "Tag '$tag' does not match version_regex." }
        $version = if ($m.Groups["version"].Success) { $m.Groups["version"].Value } else { $m.Value }
        $assets = @($release.assets)
        $escapedTag = [Uri]::EscapeDataString($tag)
        $sourceUrl = "https://github.com/$repo/archive/refs/tags/$escapedTag.zip"
        $sourceHash = ""
        $repoName = ($repo -split "/")[-1]; $sourceExtract = "$repoName-$($tag -replace '/', '-')"
      }

      $assetPattern = [string](Get-Prop $recipe "asset_pattern" "")
      $primary = $null
      if ($assetPattern) { $primary = @($assets | Where-Object { $_.name -match $assetPattern }) | Select-Object -First 1 }
      if (-not $primary) {
        $primary = @($assets | Where-Object { $_.name -match "(?i)(portable|universal|any|windows.*(x64|amd64)|\.ps1$|\.exe$|\.zip$)" } | Sort-Object {
          if ($_.name -match "(?i)(portable|universal|any|\.ps1$)") { 0 } elseif ($_.name -match "(?i)(windows|win).*(x64|amd64)") { 1 } else { 2 }
        }) | Select-Object -First 1
      }

      $requested = ([string](Get-Prop $recipe "mode" "auto")).ToLowerInvariant()
      $policy = ([string](Get-Prop $recipe "platform_policy" "universal-first")).ToLowerInvariant()
      $hardware = [bool](Get-Prop $recipe "hardware_sensitive" $false)
      $native = [bool](Get-Prop $recipe "native_modules" $false)
      if ($requested -ne "auto") { $mode = $requested; $reason = "explicit:$requested" }
      elseif ($policy -eq "force-local" -or $hardware) { $mode = "local"; $reason = if ($hardware) { "hardware-sensitive" } else { "policy:force-local" } }
      elseif ($primary -and $policy -eq "universal-first") { $mode = "upstream"; $reason = "compatible-upstream-asset" }
      elseif ($native) { $mode = "hybrid"; $reason = "portable-preparation-plus-native-completion" }
      else { $mode = "cloud"; $reason = "portable-cloud-build" }
      if ($mode -eq "upstream" -and -not $primary) { throw "Upstream mode has no compatible asset." }
      if ($mode -eq "local" -and -not $sourceHash) {
        $sourceCache = Join-Path $cacheRoot ("local-source-" + (Get-TextSha256 $sourceUrl))
        $null = Get-CachedFile $sourceUrl $sourceCache
        $sourceHash = Get-FileSha256 $sourceCache
      }

      $upstreamUrls = [Collections.Generic.List[string]]::new()
      $upstreamHashes = [Collections.Generic.List[string]]::new()
      if ($mode -eq "upstream") {
        $selected = [Collections.Generic.List[object]]::new(); $selected.Add($primary)
        foreach ($extraPattern in @(Get-Prop $recipe "extra_assets" @())) {
          $extra = @($assets | Where-Object { $_.name -match [string]$extraPattern }) | Select-Object -First 1
          if (-not $extra) { throw "Missing extra asset '$extraPattern'." }; $selected.Add($extra)
        }
        foreach ($asset in $selected) {
          $upstreamUrls.Add([string]$asset.browser_download_url)
          $upstreamHashes.Add((AssetHash $asset $cacheRoot))
        }
      }

      $builderType = [string](Get-Prop $recipe "build_type" "auto")
      $builderHash = Get-BuilderSha256 $builderType $buildersDir
      $canonical = [ordered]@{
        engine = $engine; builder_sha256 = $builderHash; recipe = $recipe
        source_type = $sourceType; version = $version; tag = $tag; mode = $mode
      }
      $fingerprint = Get-TextSha256 ($canonical | ConvertTo-Json -Depth 20 -Compress)
      $artifactName = "$name-$version-$($fingerprint.Substring(0, 12))-windows-x64.zip"
      $releaseTag = "$name-v$version"
      $published = $null
      if ($mode -in @("cloud","hybrid") -and -not $force) {
        try {
          $own = Invoke-RestMethod ("https://api.github.com/repos/{0}/releases/tags/{1}" -f $targetRepo, $releaseTag) -Headers $headers
          $published = @($own.assets | Where-Object name -eq $artifactName) | Select-Object -First 1
        } catch {
          if ($null -ne $_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -ne 404) { throw }
        }
      }
      $publishedHash = if ($published) { AssetHash $published $cacheRoot } else { "" }
      [pscustomobject]@{
        name = $name; version = $version; tag = $tag; source_type = $sourceType; mode = $mode; reason = $reason
        fingerprint = $fingerprint; artifact_name = $artifactName; release_tag = $releaseTag
        needs_build = ($mode -in @("cloud","hybrid") -and -not $published)
        published_url = if ($published) { [string]$published.browser_download_url } else { "" }; published_hash = $publishedHash
        source_url = $sourceUrl; source_hash = $sourceHash; source_extract_dir = $sourceExtract
        upstream_urls = @($upstreamUrls); upstream_hashes = @($upstreamHashes)
        architectures = @(Get-Prop $recipe "architectures" @("64bit")); recipe = $recipe; error = $null
      }
    } catch {
      [pscustomobject]@{ name = $name; error = $_.Exception.Message }
    }
  } -ThrottleLimit $ThrottleLimit)

  $errors = @($results | Where-Object error)
  if ($errors) { throw (($errors | ForEach-Object { "[$($_.name)] $($_.error)" }) -join [Environment]::NewLine) }
  return @($results | Sort-Object name)
}

function Invoke-BuildPhase {
  param([object[]]$Plans)
  if ($PackageName) {
    $allPlans = @($Plans); $allByName = @{}; foreach ($candidate in $allPlans) { $allByName[$candidate.name] = $candidate }
    if (-not $allByName.ContainsKey($PackageName)) { throw "Planned package '$PackageName' was not found." }
    $selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); $null = $selected.Add($PackageName)
    $pending = [Collections.Generic.Queue[string]]::new(); $pending.Enqueue($PackageName)
    while ($pending.Count) {
      $current = $pending.Dequeue()
      foreach ($dependency in @(Get-Prop $allByName[$current].recipe "tool_dependencies" @())) {
        if (-not $allByName.ContainsKey([string]$dependency)) { throw "Missing tool dependency '$dependency'." }
        if ($selected.Add([string]$dependency)) { $pending.Enqueue([string]$dependency) }
      }
    }
    $Plans = @($allPlans | Where-Object { $selected.Contains([string]$_.name) })
  }

  $levels = Get-DependencyLevels @($Plans | ForEach-Object { $_.recipe })
  $byName = @{}; foreach ($plan in $Plans) { $byName[$plan.name] = $plan }
  $stageRoot = [IO.Path]::GetFullPath($StageDir); $null = New-Item -ItemType Directory -Force -Path $stageRoot
  $cacheRoot = [IO.Path]::GetFullPath($CacheDir)
  $activeBuildCount = [Math]::Max(1, @($Plans | Where-Object needs_build).Count)
  $requiredToolNames = @($Plans | Where-Object needs_build | ForEach-Object { @(Get-Prop $_.recipe "tool_dependencies" @()) } | Sort-Object -Unique)
  $commonPath = $CommonPath
  $buildersDir = $BuildersDir
  $failedTypes = [System.Collections.Concurrent.ConcurrentDictionary[string, bool]]::new()
  $all = [Collections.Generic.List[object]]::new()

  foreach ($level in $levels) {
    $levelPlans = @($level | ForEach-Object { $byName[$_] })
    $throttle = if ($levelPlans.Count -eq 1) { 1 } else { $ThrottleLimit }

    $results = @($levelPlans | ForEach-Object -Parallel {
      $plan = $_
      $stageRoot = $using:stageRoot
      $cacheRoot = $using:cacheRoot
      $activeBuildCount = $using:activeBuildCount
      $requiredToolNames = $using:requiredToolNames
      $buildersDir = $using:buildersDir
      $failedTypes = $using:failedTypes

      . $using:commonPath

      $type = ([string](Get-Prop $plan.recipe "build_type" "auto")).ToLowerInvariant()
      if ($failedTypes.ContainsKey($type)) {
        return [pscustomobject]@{ name = $plan.name; status = "cancelled"; archive = ""; hash = ""; bootstrap_path = ""; error = "Cancelled due to prior failure in group '$type'" }
      }

      $work = Join-Path $stageRoot ("work-" + $plan.name + "-" + $plan.fingerprint.Substring(0, 8))
      try {
        $isToolchain = [bool](Get-Prop $plan.recipe "toolchain" (Get-Prop $plan.recipe "bootstrap" $false))
        $bootstrap = ($requiredToolNames -contains [string]$plan.name)
        if ($bootstrap -and -not $isToolchain) { throw "Required build tool '$($plan.name)' is not marked as a toolchain." }
        $bootstrapPath = ""
        if ($bootstrap -and $plan.mode -eq "upstream") {
          $toolRoot = Join-Path $cacheRoot ("toolchain/" + $plan.name + "/" + $plan.version)
          $marker = Join-Path $toolRoot ".complete"
          if (-not (Test-Path $marker)) {
            $null = New-Item -ItemType Directory -Force -Path $toolRoot
            $url = [string]$plan.upstream_urls[0]; $hash = [string]$plan.upstream_hashes[0]; $asset = Join-Path $cacheRoot ("tool-" + $hash)
            $null = Get-CachedFile $url $asset $hash
            if ($url -match "(?i)\.zip($|\?)") { Expand-Archive $asset $toolRoot -Force }
            elseif ($url -match "(?i)\.7z($|\?)") { Invoke-Checked "7z" @("x", "-y", "-o$toolRoot", $asset) }
            else { Copy-Item $asset $toolRoot -Force }
            Set-Content $marker $plan.version -Encoding ascii
          }
          $exe = [string](Get-Prop $plan.recipe "bootstrap_exe" (Get-Prop $plan.recipe "bin"))
          $found = Get-ChildItem $toolRoot -Filter $exe -File -Recurse | Select-Object -First 1
          if (-not $found) { throw "Tool '$exe' not found" }
          $bootstrapPath = $found.DirectoryName
        }

        if (-not $plan.needs_build) {
          return [pscustomobject]@{ name = $plan.name; status = "reused"; archive = ""; hash = $plan.published_hash; bootstrap_path = $bootstrapPath; error = $null }
        }

        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        $sourceDir = Join-Path $work "source"
        $packageDir = Join-Path $work "package"
        $outputDir = Join-Path $stageRoot $plan.name
        $null = New-Item -ItemType Directory -Force -Path $sourceDir, $packageDir, $outputDir

        $sourceArchive = Join-Path $cacheRoot ("source-" + $plan.fingerprint)
        $null = Get-CachedFile $plan.source_url $sourceArchive $plan.source_hash
        Invoke-Checked "tar" @("-xf", $sourceArchive, "-C", $sourceDir)
        $root = Get-ChildItem $sourceDir -Directory | Select-Object -First 1
        $sourceRoot = if ($root) { $root.FullName } else { $sourceDir }

        foreach ($depUrl in @(Get-Prop $plan.recipe "git_dependencies" @())) {
          $depName = ($depUrl -split '/')[-1] -replace '\.git$', ''
          $sourceParent = Split-Path $sourceRoot -Parent
          $depTarget = Join-Path $sourceParent $depName
          if (-not (Test-Path $depTarget)) {
            Invoke-Checked "git" @("clone", "--depth", "1", [string]$depUrl, $depTarget)
          }

          $junctionLocations = @(
            (Join-Path $sourceRoot $depName),
            (Join-Path (Split-Path $sourceParent -Parent) $depName)
          )
          foreach ($loc in $junctionLocations) {
            if (-not (Test-Path $loc)) {
              New-Item -ItemType Junction -Path $loc -Target $depTarget -Force -ErrorAction SilentlyContinue | Out-Null
            }
          }

          if ($type -eq "dotnet") {
            $depProjects = Get-ChildItem -Path $depTarget -Filter "*.*proj" -Recurse -File | Where-Object {
              (Get-Content -LiteralPath $_.FullName -Raw) -notmatch "(?i)<COMReference"
            }
            foreach ($projFile in $depProjects) {
              try {
                Invoke-Checked "dotnet" @("build", $projFile.FullName, "-c", "Release", "-p:TreatWarningsAsErrors=false", "-warnaserror:false")
              } catch {
                Write-Warning "Skipped non-critical dependency project $($projFile.Name)"
              }
            }
          }
        }

        if ($type -eq "auto") {
          $type = if (Test-Path (Join-Path $sourceRoot "package.json")) { "node" }
                  elseif (Test-Path (Join-Path $sourceRoot "Cargo.toml")) { "rust" }
                  elseif (Test-Path (Join-Path $sourceRoot "go.mod")) { "go" }
                  elseif ((Test-Path (Join-Path $sourceRoot "pyproject.toml")) -or (Test-Path (Join-Path $sourceRoot "requirements.txt"))) { "python" }
                  else { "powershell" }
        }

        if ($plan.mode -eq "hybrid") {
          Copy-Item (Join-Path $sourceRoot "*") $packageDir -Recurse -Force
          Push-Location $packageDir
          try {
            switch ($type) {
              "python" {
                $wheel = Join-Path $packageDir ".meta/wheelhouse"
                $null = New-Item -ItemType Directory -Force -Path $wheel
                if (Test-Path "requirements.txt") {
                  Invoke-Checked "python" @("-m", "pip", "download", "--disable-pip-version-check", "--dest", $wheel, "-r", "requirements.txt")
                }
              }
              "node" {
                $store = Join-Path $packageDir ".meta/pnpm-store"
                Invoke-Checked "corepack" @("enable")
                Invoke-Checked "pnpm" @("fetch", "--prod", "--frozen-lockfile", "--store-dir", $store)
              }
              "bun" {
                $bunCache = Join-Path $packageDir ".meta/bun-cache"
                $old = $env:BUN_INSTALL_CACHE_DIR
                $env:BUN_INSTALL_CACHE_DIR = $bunCache
                try { Invoke-Checked "bun" @("install", "--frozen-lockfile", "--ignore-scripts") }
                finally { $env:BUN_INSTALL_CACHE_DIR = $old }
              }
              "go" { Invoke-Checked "go" @("mod", "vendor") }
              "rust" {
                $vendor = Join-Path $packageDir "vendor"
                Invoke-Checked "cargo" @("vendor", $vendor)
                $cargoDir = Join-Path $packageDir ".cargo"
                $null = New-Item -ItemType Directory -Force -Path $cargoDir
                @('[source.crates-io]', 'replace-with = "vendored-sources"', '[source.vendored-sources]', 'directory = "vendor"') |
                  Set-Content -LiteralPath (Join-Path $cargoDir "config.toml") -Encoding utf8
              }
            }
          } finally { Pop-Location }
        } else {
          $builderFile = Join-Path $buildersDir "$type.ps1"
          if (-not (Test-Path -LiteralPath $builderFile)) { throw "Builder script not found for '$type': $builderFile" }
          & $builderFile -Plan $plan -SourceRoot $sourceRoot -PackageDir $packageDir -CacheRoot $cacheRoot
        }

        $junkDirs = @([System.IO.Directory]::EnumerateDirectories($packageDir, "*", [System.IO.SearchOption]::AllDirectories)) |
          Sort-Object { $_.Length } -Descending
        foreach ($dir in $junkDirs) {
          $leaf = [System.IO.Path]::GetFileName($dir)
          if ($leaf -match "^(test|tests|docs|__pycache__|darwin|linux|freebsd|android)$") {
            if ([System.IO.Directory]::Exists($dir)) { [System.IO.Directory]::Delete($dir, $true) }
          }
        }

        $junkFiles = [System.IO.Directory]::EnumerateFiles($packageDir, "*", [System.IO.SearchOption]::AllDirectories)
        foreach ($file in $junkFiles) {
          $ext = [System.IO.Path]::GetExtension($file)
          if ($ext -match "^\.(map|pdb|d\.ts|pyc|so|dylib)$") {
            if ([System.IO.File]::Exists($file)) { [System.IO.File]::Delete($file) }
          }
        }

        foreach ($p in @(Get-Prop $plan.recipe "persist" @())) {
          $pStr = [string]$p
          if ([System.IO.Path]::HasExtension($pStr)) {
            $targetFile = Join-Path $packageDir $pStr
            if (-not (Test-Path -LiteralPath $targetFile)) {
              $parentDir = Split-Path $targetFile -Parent
              if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
                New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
              }
              New-Item -ItemType File -Force -Path $targetFile | Out-Null
            }
          }
        }

        if (-not (Get-ChildItem $packageDir -File -Recurse | Select-Object -First 1)) { throw "Empty package" }
        $archive = Join-Path $outputDir $plan.artifact_name
        $level = [int](Get-Prop $plan.recipe "compression_level" 5)
        $threads = [Math]::Max(1, [int]([Environment]::ProcessorCount / [Math]::Max(1, $activeBuildCount)))
        Invoke-Checked "7z" @("a", "-tzip", "-mx=$level", "-mm=Deflate", "-mmt=$threads", $archive, (Join-Path $packageDir "*"))
        [pscustomobject]@{ name = $plan.name; status = "built"; archive = $plan.artifact_name; hash = (Get-FileSha256 $archive); bootstrap_path = $bootstrapPath; error = $null }
      } catch {
        $null = $failedTypes.TryAdd($type, $true)
        [pscustomobject]@{ name = $plan.name; status = "failed"; archive = ""; hash = ""; bootstrap_path = ""; error = $_.Exception.Message }
      } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
      }
    } -ThrottleLimit $throttle)

    foreach ($result in $results) {
      $all.Add($result)
      if ($result.bootstrap_path) {
        $env:PATH = "$($result.bootstrap_path);$env:PATH"
        if ($env:GITHUB_PATH) { Add-Content $env:GITHUB_PATH $result.bootstrap_path }
      }
    }
  }

  $errors = @($all | Where-Object error)
  if ($errors) { throw (($errors | ForEach-Object { "[$($_.name)] $($_.error)" }) -join [Environment]::NewLine) }
  Write-Utf8Json (Join-Path $stageRoot "results.json") ([ordered]@{ engine_version = $EngineVersion; results = @($all | Sort-Object name) })
}

function Get-LocalCommands {
  param([object]$Plan)
  $custom = @(Get-Prop $Plan.recipe "local_commands" @())
  if ($custom.Count) { return $custom }
  $type = ([string](Get-Prop $Plan.recipe "build_type" "auto")).ToLowerInvariant()
  $name = [string]$Plan.name; $bin = [string](Get-Prop $Plan.recipe "bin" "")
  $offline = $Plan.mode -eq "hybrid"
  $commands = [Collections.Generic.List[string]]::new()
  $commands.Add('$ErrorActionPreference = "Stop"')
  $commands.Add('$jobs = [Math]::Max(1, [Environment]::ProcessorCount)')
  switch ($type) {
    "python" {
      $entry = [string](Get-Prop $Plan.recipe "entrypoint" "$name.py")
      $commands.Add('python -m venv "$dir\.meta\venv"')
      $pip = '& "$dir\.meta\venv\Scripts\python.exe" -m pip install --disable-pip-version-check'
      if ($offline) { $pip += ' --no-index --find-links "$dir\.meta\wheelhouse"' }
      $commands.Add(('if (Test-Path -LiteralPath "$dir\requirements.txt") {{ {0} -r "$dir\requirements.txt" }}' -f $pip))
      $commands.Add(('@("@echo off", ''& "%~dp0.meta\venv\Scripts\python.exe" "%~dp0{0}" %*'') | Set-Content -LiteralPath "$dir\{1}.cmd" -Encoding ascii' -f ($entry -replace '/', '\'), $name))
    }
    "go" {
      $entry = [string](Get-Prop $Plan.recipe "entrypoint" ".")
      $vendor = if ($offline) { "-mod=vendor " } else { "" }
      $commands.Add(('go build {0}-trimpath -ldflags="-s -w" -o "$dir\{1}.exe" {2}' -f $vendor, $name, $entry))
    }
    "rust" {
      $flag = if ($offline) { " --offline" } else { "" }
      $commands.Add("cargo build --locked --release$flag")
      $output = [string](Get-Prop $Plan.recipe "local_output" "target\release\$name.exe")
      $commands.Add(('Copy-Item -LiteralPath "{0}" -Destination "$dir\{1}.exe" -Force' -f $output, $name))
    }
    "node" {
      $commands.Add("corepack enable")
      $install = if ($offline) { 'pnpm install --offline --frozen-lockfile --store-dir "$dir\.meta\pnpm-store"' } else { "pnpm install --frozen-lockfile" }
      $commands.Add($install)
      $commands.Add("pnpm run build")
      $commands.Add(('@("@echo off", ''node "%~dp0build\server\index.js" %*'') | Set-Content -LiteralPath "$dir\{0}.cmd" -Encoding ascii' -f $name))
    }
    "bun" {
      if ($offline) { $commands.Add('$env:BUN_INSTALL_CACHE_DIR = "$dir\.meta\bun-cache"'); $commands.Add("bun install --offline --frozen-lockfile") }
      else { $commands.Add("bun install --frozen-lockfile") }
      $commands.Add("bun run build")
    }
    "powershell" {}
    default { throw "Local/hybrid recipe '$name' requires build_type or local_commands." }
  }
  if ($bin) { $commands.Add(('if (-not (Test-Path -LiteralPath "$dir\{0}")) {{ throw "Expected output {0} was not produced." }}' -f $bin)) }
  return @($commands)
}

function Get-ToolDepends {
  param([object]$Plan)
  $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($d in @(Get-Prop $Plan.recipe "depends" @())) { $null = $set.Add([string]$d) }
  foreach ($d in @(Get-Prop $Plan.recipe "tool_dependencies" @())) { $null = $set.Add([string]$d) }
  $type = ([string](Get-Prop $Plan.recipe "build_type" "")).ToLowerInvariant()
  if ($type -eq "node" -or $type -eq "bun") { $null = $set.Add("nodejs") }
  if ($type -eq "python") { $null = $set.Add("python") }
  if ($Plan.mode -in @("local","hybrid")) {
    $tool = switch ($type) { "go" { "go" }; "rust" { "rust" }; default { $null } }
    if ($tool) { $null = $set.Add($tool) }
  }
  return @($set | Sort-Object)
}

function Invoke-FinalizePhase {
  param([object[]]$Plans)
  $results = @{}
  foreach ($stageResultsPath in @(Get-ChildItem -LiteralPath ([IO.Path]::GetFullPath($StageDir)) -Filter "results.json" -File -Recurse -ErrorAction SilentlyContinue)) {
    foreach ($r in @((Get-Content $stageResultsPath.FullName -Raw | ConvertFrom-Json).results)) { $results[$r.name] = $r }
  }
  $targetRepo = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { "Anri2021/scoop-bucket" }
  $null = New-Item -ItemType Directory -Force -Path $BucketDir
  $lockPackages = [ordered]@{}
  $staged = @{}
  $successfulPlans = [Collections.Generic.List[object]]::new()

  foreach ($plan in @($Plans | Where-Object needs_build)) {
    $result = $results[$plan.name]
    if (-not $result -or $result.status -ne "built") {
      Write-Warning "Skipping '$($plan.name)' (Status: $($result.status), Error: $($result.error))"
      continue
    }
    $archive = Get-ChildItem -LiteralPath $StageDir -Filter $result.archive -File -Recurse | Select-Object -First 1
    if (-not $archive -or (Get-FileSha256 $archive.FullName) -ne $result.hash) {
      Write-Warning "Staged archive missing or hash mismatch for '$($plan.name)'."
      continue
    }
    $staged[$plan.name] = $archive.FullName
    $successfulPlans.Add($plan)
  }

  if (-not $NoPublish -and $staged.Count) {
    $publishItems = @($successfulPlans | ForEach-Object { [pscustomobject]@{ name = $_.name; release_tag = $_.release_tag; version = $_.version; fingerprint = $_.fingerprint; archive = $staged[$_.name] } })
    $publishResults = @($publishItems | ForEach-Object -Parallel {
      $item = $_; $repo = $using:targetRepo
      $ghExe = (Get-Command gh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
      function Invoke-GhChecked { param([string]$Executable, [string[]]$Arguments); & $Executable @Arguments 2>&1 | Out-Host; if ($LASTEXITCODE -ne 0) { throw "gh failed with code $LASTEXITCODE" } }
      try {
        & $ghExe release view $item.release_tag --repo $repo 2>$null 1>$null
        if ($LASTEXITCODE -ne 0) { Invoke-GhChecked $ghExe @("release", "create", $item.release_tag, "--repo", $repo, "--title", "$($item.name) $($item.version)", "--notes", "Meta-Bucket build $($item.fingerprint).") }
        Invoke-GhChecked $ghExe @("release", "upload", $item.release_tag, $item.archive, "--repo", $repo, "--clobber")
        [pscustomobject]@{ name = $item.name; error = $null }
      } catch {
        [pscustomobject]@{ name = $item.name; error = $_.Exception.Message }
      }
    } -ThrottleLimit ([Math]::Min(6, $publishItems.Count)))

    $publishErrors = @($publishResults | Where-Object error)
    if ($publishErrors) { throw (($publishErrors | ForEach-Object { "[$($_.name)] $($_.error)" }) -join [Environment]::NewLine) }

    foreach ($item in $publishItems) {
      $current = [IO.Path]::GetFileName($item.archive); $prefix = "$($item.name)-$($item.version)-"
      $assetNames = @(& gh release view $item.release_tag --repo $targetRepo --json assets --jq '.assets[].name')
      if ($LASTEXITCODE -ne 0) { throw "Unable to enumerate assets for '$($item.name)'." }
      foreach ($assetName in $assetNames) {
        if ($assetName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $assetName -ne $current) {
          Invoke-Checked "gh" @("release", "delete-asset", $item.release_tag, $assetName, "--repo", $targetRepo, "--yes")
        }
      }
    }
  }

  $lockFilePath = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($RecipesPath))) "recipes.lock.json"
  $existingLock = if (Test-Path -LiteralPath $lockFilePath) { Get-Content -LiteralPath $lockFilePath -Raw -Encoding utf8 | ConvertFrom-Json } else { $null }
  $existingPackages = if ($existingLock) { Get-Prop $existingLock "packages" } else { $null }
  $successfulBuildNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($sp in $successfulPlans) { $null = $successfulBuildNames.Add([string]$sp.name) }
  
  foreach ($plan in $Plans | Sort-Object name) {
    if ($plan.needs_build -and -not $successfulBuildNames.Contains($plan.name)) {
      Write-Warning "Package '$($plan.name)' was not built; retaining existing lock entry."
      if ($existingPackages -and $existingPackages.PSObject.Properties[$plan.name]) {
        $lockPackages[$plan.name] = $existingPackages.PSObject.Properties[$plan.name].Value
      }
      continue
    }

    $urls = @(); $hashes = @(); $extractDir = ""
    if ($plan.mode -eq "upstream") { $urls = @($plan.upstream_urls); $hashes = @($plan.upstream_hashes); $extractDir = [string](Get-Prop $plan.recipe "extract_dir" "") }
    elseif ($plan.mode -eq "local") { $urls = @($plan.source_url); $hashes = @($plan.source_hash); $extractDir = [string]$plan.source_extract_dir }
    else {
      if ($plan.needs_build) {
        $result = $results[$plan.name]
        $archive = [IO.FileInfo]::new([string]$staged[$plan.name])
        if ($NoPublish) { $urls = @($archive.FullName) } else { $urls = @("https://github.com/$targetRepo/releases/download/$($plan.release_tag)/$($plan.artifact_name)") }
        $hashes = @($result.hash)
      } else { $urls = @($plan.published_url); $hashes = @($plan.published_hash) }
    }

    $download = [ordered]@{ url = if ($urls.Count -eq 1) { $urls[0] } else { $urls }; hash = if ($hashes.Count -eq 1) { $hashes[0] } else { $hashes } }
    if ($extractDir) { $download.extract_dir = $extractDir }
    $manifest = [ordered]@{ version = $plan.version; description = [string](Get-Prop $plan.recipe "description"); homepage = [string](Get-Prop $plan.recipe "homepage"); license = [string](Get-Prop $plan.recipe "license") }
    $architectures = @($plan.architectures)
    if ($architectures.Count -eq 1 -and $architectures[0] -eq "64bit") { $manifest.url = $download.url; $manifest.hash = $download.hash; if ($extractDir) { $manifest.extract_dir = $extractDir } }
    else { $manifest.architecture = [ordered]@{}; foreach ($arch in $architectures) { $manifest.architecture[$arch] = $download } }
    $bin = Get-Prop $plan.recipe "bin"
    if (-not $bin) {
      $type = ([string](Get-Prop $plan.recipe "build_type" "")).ToLowerInvariant()
      $bin = if ($type -in @("node","python","powershell")) { "$($plan.name).cmd" } else { "$($plan.name).exe" }
    }
    $manifest.bin = $bin
    $depends = @(Get-ToolDepends $plan); if ($depends.Count) { $manifest.depends = if ($depends.Count -eq 1) { $depends[0] } else { $depends } }
    if ($plan.mode -in @("local","hybrid")) { $manifest.pre_install = Get-LocalCommands $plan }
    $persist = @(Get-Prop $plan.recipe "persist" @()); if ($persist.Count) { $manifest.persist = if ($persist.Count -eq 1) { $persist[0] } else { $persist } }
    $shortcuts = Get-Prop $plan.recipe "shortcuts"; if ($shortcuts) { $manifest.shortcuts = $shortcuts }
    Write-Utf8Json (Join-Path $BucketDir "$($plan.name).json") $manifest 20
    $lockPackages[$plan.name] = [ordered]@{ version = $plan.version; tag = $plan.tag; mode = $plan.mode; reason = $plan.reason; fingerprint = $plan.fingerprint; artifact = $plan.artifact_name }
  }

  if (-not $PackageName) {
    $active = [Collections.Generic.HashSet[string]]::new([string[]]@($Plans.name), [StringComparer]::OrdinalIgnoreCase)
    Get-ChildItem $BucketDir -Filter "*.json" -File | Where-Object { -not $active.Contains($_.BaseName) } | Remove-Item -Force
  }

  $recipesHash = Get-FileSha256 $RecipesPath
  Write-Utf8Json (Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($RecipesPath))) "recipes.lock.json") ([ordered]@{ engine_version = $EngineVersion; recipes_sha256 = $recipesHash; packages = $lockPackages }) 20

  # Cache Garbage Collector (Mark and Sweep)
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

$RecipesPath = [IO.Path]::GetFullPath($RecipesPath)
$PlanPath = [IO.Path]::GetFullPath($PlanPath)
$StageDir = [IO.Path]::GetFullPath($StageDir)
$BucketDir = [IO.Path]::GetFullPath($BucketDir)
$CacheDir = [IO.Path]::GetFullPath($CacheDir)
if (-not (Test-Path $RecipesPath)) { throw "Recipes file not found: $RecipesPath" }
$config = Get-Content $RecipesPath -Raw -Encoding utf8 | ConvertFrom-Json
$recipes = @($config.recipes); Assert-Recipes $recipes
$targetRepository = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { "Anri2021/scoop-bucket" }

if ($Phase -in @("Plan","All")) {
  if ($PackageName) {
    $byName = @{}; foreach ($r in $recipes) { $byName[$r.name] = $r }
    if (-not $byName.ContainsKey($PackageName)) { throw "Recipe '$PackageName' not found." }
    $selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $null = $selected.Add($PackageName)
    $queue = [Collections.Generic.Queue[string]]::new(); $queue.Enqueue($PackageName)
    while ($queue.Count) {
      $curr = $queue.Dequeue()
      foreach ($dep in @(Get-Prop $byName[$curr] "tool_dependencies" @())) {
        if ($selected.Add([string]$dep)) { $queue.Enqueue([string]$dep) }
      }
    }
    $recipes = @($recipes | Where-Object { $selected.Contains($_.name) })
  }
  $plans = Resolve-Plans $recipes $targetRepository $EngineVersion $PipelineSha256 -Force:$ForceRebuild
  $planDocument = [ordered]@{ engine_version = $EngineVersion; engine_sha256 = $EngineSha256; build_environment_sha256 = $BuildEnvironmentSha256; pipeline_sha256 = $PipelineSha256; build_environment = $BuildEnvironment; recipes_sha256 = (Get-FileSha256 $RecipesPath); packages = $plans }
  Write-Utf8Json $PlanPath $planDocument 30
  $plans | Format-Table name,version,mode,reason,needs_build -AutoSize
  if ($ValidateOnly) { exit 0 }
}
if ($Phase -in @("Build","Finalize")) {
  if (-not (Test-Path $PlanPath)) { throw "Plan not found: $PlanPath" }
  $planDocument = Get-Content $PlanPath -Raw -Encoding utf8 | ConvertFrom-Json
  if ($planDocument.engine_version -ne $EngineVersion) { throw "Plan engine version mismatch." }
  if ($planDocument.engine_sha256 -ne $EngineSha256) { throw "Plan engine fingerprint mismatch." }
  if ($planDocument.pipeline_sha256 -ne $PipelineSha256) { throw "Plan pipeline fingerprint mismatch." }
  $plans = @($planDocument.packages)
}
if ($Phase -in @("Build","All")) { Invoke-BuildPhase $plans }
if ($Phase -in @("Finalize","All")) { Invoke-FinalizePhase $plans }
