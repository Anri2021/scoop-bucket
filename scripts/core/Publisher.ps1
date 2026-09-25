<#
.SYNOPSIS
  Generation of Scoop manifests, release management, and lockfile synchronization.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
  param(
    [object[]]$Plans,
    [string]$StageDir,
    [string]$BucketDir,
    [string]$RecipesPath,
    [string]$TargetRepository,
    [string]$EngineVersion,
    [string]$PackageName = "",
    [switch]$NoPublish
  )

  $results = @{}
  foreach ($stageResultsPath in @(Get-ChildItem -LiteralPath ([IO.Path]::GetFullPath($StageDir)) -Filter "results.json" -File -Recurse -ErrorAction SilentlyContinue)) {
    foreach ($r in @((Get-Content $stageResultsPath.FullName -Raw | ConvertFrom-Json).results)) { $results[$r.name] = $r }
  }

  $null = New-Item -ItemType Directory -Force -Path $BucketDir
  $lockPackages = [ordered]@{}
  $staged = @{}
  $successfulPlans = [Collections.Generic.List[object]]::new()

  foreach ($plan in @($Plans | Where-Object needs_build)) {
    $result = if ($results.ContainsKey($plan.name)) { $results[$plan.name] } else { $null }
    $status = if ($result) { [string](Get-Prop $result "status" "missing") } else { "missing" }
    $errorMsg = if ($result) { [string](Get-Prop $result "error" "No error reported") } else { "Build step did not run or artifact was not found" }
    if ($status -ne "built") {
      Write-Warning "Skipping '$($plan.name)' (Status: $status, Error: $errorMsg)"
      continue
    }
    $archiveName = [string](Get-Prop $result "archive" "")
    $archiveHash = [string](Get-Prop $result "hash" "")
    $archive = if ($archiveName) { Get-ChildItem -LiteralPath $StageDir -Filter $archiveName -File -Recurse | Select-Object -First 1 } else { $null }
    if (-not $archive -or (Get-FileSha256 $archive.FullName) -ne $archiveHash) {
      Write-Warning "Staged archive missing or hash mismatch for '$($plan.name)'."
      continue
    }
    $staged[$plan.name] = $archive.FullName
    $successfulPlans.Add($plan)
  }

  if (-not $NoPublish -and $staged.Count) {
    $publishItems = @($successfulPlans | ForEach-Object { [pscustomobject]@{ name = $_.name; release_tag = $_.release_tag; version = $_.version; fingerprint = $_.fingerprint; archive = $staged[$_.name] } })
    $publishResults = @($publishItems | ForEach-Object -Parallel {
      $item = $_; $repo = $using:TargetRepository
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
      $assetNames = @(& gh release view $item.release_tag --repo $TargetRepository --json assets --jq '.assets[].name')
      if ($LASTEXITCODE -ne 0) { throw "Unable to enumerate assets for '$($item.name)'." }
      foreach ($assetName in $assetNames) {
        if ($assetName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $assetName -ne $current) {
          Invoke-Checked "gh" @("release", "delete-asset", $item.release_tag, $assetName, "--repo", $TargetRepository, "--yes")
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
        if ($NoPublish) { $urls = @($archive.FullName) } else { $urls = @("https://github.com/$TargetRepository/releases/download/$($plan.release_tag)/$($plan.artifact_name)") }
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
}
