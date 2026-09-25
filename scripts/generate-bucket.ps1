<#
.SYNOPSIS
  Meta-Bucket v4: deterministic planner, distributed builder and transactional finalizer.
  Cloud packages target windows-x64.zip archives for native Scoop extraction.
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
$GraphPath = Join-Path $EngineDir "core/Graph.ps1"
$PlannerPath = Join-Path $EngineDir "core/Planner.ps1"
$PublisherPath = Join-Path $EngineDir "core/Publisher.ps1"
$CacheModulePath = Join-Path $EngineDir "core/Cache.ps1"

. $CommonPath
. $GraphPath
. $PlannerPath
. $PublisherPath
. $CacheModulePath

$BuildersDir = Join-Path $EngineDir "builders"
$EngineVersion = "4.0"
$EngineSha256 = (Get-FileSha256 $EnginePath).ToLowerInvariant()
$BuildEnvironmentPath = [IO.Path]::GetFullPath($BuildEnvironmentPath)
if (-not (Test-Path -LiteralPath $BuildEnvironmentPath)) { throw "Build environment file not found: $BuildEnvironmentPath" }
$BuildEnvironment = Get-Content -LiteralPath $BuildEnvironmentPath -Raw -Encoding utf8 | ConvertFrom-Json
$BuildEnvironmentSha256 = (Get-FileSha256 $BuildEnvironmentPath)
$PipelineSha256 = Get-PipelineSha256 -EnginePath $EnginePath -BuildEnvironmentPath $BuildEnvironmentPath

function Invoke-BuildPhase {
  param([object[]]$Plans)
  if ($PackageName) {
    $Plans = Get-DependencyClosure -Recipes $Plans -PackageName $PackageName
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
          Push-Location $sourceRoot
          try {
            & $builderFile -Plan $plan -SourceRoot $sourceRoot -PackageDir $packageDir -CacheRoot $cacheRoot
          } finally {
            Pop-Location
          }
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
    $recipes = Get-DependencyClosure -Recipes $recipes -PackageName $PackageName
  }
  $plans = Resolve-Plans -Recipes $recipes -TargetRepository $targetRepository -Engine $EngineVersion -EngineHash $PipelineSha256 -CacheDir $CacheDir -CommonPath $CommonPath -BuildersDir $BuildersDir -ThrottleLimit $ThrottleLimit -Force:$ForceRebuild
  $planDocument = [ordered]@{ engine_version = $EngineVersion; engine_sha256 = $EngineSha256; build_environment_sha256 = $BuildEnvironmentSha256; pipeline_sha256 = $PipelineSha256; build_environment = $BuildEnvironment; recipes_sha256 = (Get-FileSha256 $RecipesPath); packages = $plans }
  Write-Utf8Json $PlanPath $planDocument 30
  $plans | Format-Table name,version,mode,reason,needs_build -AutoSize
  if ($ValidateOnly) { exit 0 }
}
if ($Phase -in @("Build","Finalize")) {
  if (-not (Test-Path $PlanPath)) { throw "Plan not found: $PlanPath" }
  $planDocument = Get-Content $PlanPath -Raw -Encoding utf8 | ConvertFrom-Json
  if ($planDocument.engine_version -ne $EngineVersion) { throw "Plan engine version mismatch: plan has '$($planDocument.engine_version)', runner has '$EngineVersion'." }
  if ($planDocument.engine_sha256 -ne $EngineSha256) { throw "Plan engine fingerprint mismatch: plan has '$($planDocument.engine_sha256)', runner has '$EngineSha256'." }
  if ($planDocument.pipeline_sha256 -ne $PipelineSha256) { throw "Plan pipeline fingerprint mismatch: plan has '$($planDocument.pipeline_sha256)', runner has '$PipelineSha256'." }
  $plans = @($planDocument.packages)
}
if ($Phase -in @("Build","All")) { Invoke-BuildPhase $plans }
if ($Phase -in @("Finalize","All")) {
  Invoke-FinalizePhase -Plans $plans -StageDir $StageDir -BucketDir $BucketDir -RecipesPath $RecipesPath -TargetRepository $targetRepository -EngineVersion $EngineVersion -PackageName $PackageName -NoPublish:$NoPublish
  Invoke-CacheGc -Plans $plans -CacheDir $CacheDir
}
