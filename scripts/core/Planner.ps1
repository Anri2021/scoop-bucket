<#
.SYNOPSIS
  Resolution of external package releases, versions, and build fingerprints.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-Headers {
  $headers = @{ Accept="application/vnd.github+json"; "X-GitHub-Api-Version"="2022-11-28" }
  $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
  if ($token) { $headers.Authorization = "Bearer $token" }
  return $headers
}

function Resolve-Plans {
  param(
    [object[]]$Recipes,
    [string]$TargetRepository,
    [string]$Engine,
    [string]$EngineHash,
    [string]$CacheDir,
    [string]$CommonPath,
    [string]$BuildersDir,
    [int]$ThrottleLimit = 8,
    [switch]$Force
  )

  $headers = Get-Headers
  $cacheRoot = [IO.Path]::GetFullPath($CacheDir)

  $results = @($Recipes | ForEach-Object -Parallel {
    $recipe = $_
    $headers = $using:headers
    $cacheRoot = $using:cacheRoot
    $targetRepo = $using:TargetRepository
    $engine = $using:Engine
    $force = $using:Force
    $buildersDir = $using:BuildersDir

    . $using:CommonPath

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
