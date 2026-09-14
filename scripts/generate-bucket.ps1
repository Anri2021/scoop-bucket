<#
.SYNOPSIS
  Meta-Bucket v3: deterministic planner, tiered parallel builder and privileged finalizer.
#>
[CmdletBinding()]
param(
  [ValidateSet("Plan","Build","Finalize","All")][string]$Phase = "All",
  [string]$RecipesPath = "$PSScriptRoot/../recipes.json",
  [string]$PlanPath = "$PSScriptRoot/../dist/plan.json",
  [string]$StageDir = "$PSScriptRoot/../dist/stage",
  [string]$BucketDir = "$PSScriptRoot/../bucket",
  [string]$CacheDir = "$PSScriptRoot/../dist/cache",
  [ValidateRange(1,32)][int]$ThrottleLimit = [Math]::Min([Environment]::ProcessorCount, 8),
  [switch]$ForceRebuild,
  [switch]$NoPublish,
  [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$PSNativeCommandUseErrorActionPreference = $false
$EngineVersion = "3.0"

function Get-Prop {
  param([object]$Object,[string]$Name,$Default=$null)
  if ($null -eq $Object) { return $Default }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $Default }
  return $property.Value
}

function Write-Utf8Json {
  param([string]$Path,[object]$Value,[int]$Depth=20)
  $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
  $null = New-Item -ItemType Directory -Force -Path $parent
  $json = $Value | ConvertTo-Json -Depth $Depth
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path), $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Get-TextSha256 {
  param([string]$Text)
  $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-FileSha256 {
  param([string]$Path)
  $stream = [IO.File]::OpenRead($Path)
  try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
  finally { $stream.Dispose() }
}

function Invoke-Checked {
  param([string]$File,[string[]]$Arguments)
  & $File @Arguments 2>&1 | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "'$File' exited with code $LASTEXITCODE." }
}

function Get-CachedFile {
  param([string]$Url,[string]$Path,[string]$ExpectedHash="")
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $actual = Get-FileSha256 $Path
    if (-not $ExpectedHash -or $actual -eq $ExpectedHash) { return $Path }
    Remove-Item -LiteralPath $Path -Force
  }
  $null = New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)))
  Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
  $actual = Get-FileSha256 $Path
  if ($ExpectedHash -and $actual -ne $ExpectedHash) {
    Remove-Item -LiteralPath $Path -Force
    throw "SHA256 mismatch for $Url"
  }
  return $Path
}

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
  $remaining = [Collections.Generic.HashSet[string]]::new([string[]]$byName.Keys,[StringComparer]::OrdinalIgnoreCase)
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
    foreach ($name in $ready) { $null=$remaining.Remove($name); $null=$done.Add($name) }
  }
  return @($levels)
}

function Assert-Recipes {
  param([object[]]$Recipes)
  if ($Recipes.Count -eq 0) { throw "recipes.json contains no recipes." }
  $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($recipe in $Recipes) {
    $name=[string](Get-Prop $recipe "name")
    $mode=([string](Get-Prop $recipe "mode" "auto")).ToLowerInvariant()
    $source=([string](Get-Prop $recipe "source_type" "github")).ToLowerInvariant()
    $policy=([string](Get-Prop $recipe "platform_policy" "universal-first")).ToLowerInvariant()
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
  param([object[]]$Recipes,[string]$TargetRepository,[string]$Engine,[switch]$Force)
  $headers=Get-Headers
  $cacheRoot=[IO.Path]::GetFullPath($CacheDir)
  $results=@($Recipes | ForEach-Object -Parallel {
    $recipe=$_
    $headers=$using:headers
    $cacheRoot=$using:cacheRoot
    $targetRepo=$using:TargetRepository
    $engine=$using:Engine
    $force=$using:Force

    function Prop { param([object]$o,[string]$n,$d=$null); $p=$o.PSObject.Properties[$n]; if($null -eq $p -or $null -eq $p.Value){return $d}; return $p.Value }
    function FileHash { param([string]$p);$s=[IO.File]::OpenRead($p);try{return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($s)).ToLowerInvariant()}finally{$s.Dispose()} }
    function TextHash { param([string]$t);return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($t))).ToLowerInvariant() }
    function Cached { param([string]$u,[string]$p,[string]$h="");if(Test-Path -LiteralPath $p){$a=FileHash $p;if(-not $h-or$a-eq$h){return $p};Remove-Item $p -Force};$null=New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($p));Invoke-WebRequest $u -OutFile $p -UseBasicParsing;$a=FileHash $p;if($h-and$a-ne$h){throw "SHA256 mismatch: $u"};return $p }
    function AssetHash { param([object]$a);$d=[string](Prop $a "digest" "");if($d-match"^sha256:(?<h>[a-fA-F0-9]{64})$"){return $Matches.h.ToLowerInvariant()};$p=Join-Path $cacheRoot ("asset-"+[string]$a.id+"-"+[string]$a.name);$null=Cached ([string]$a.browser_download_url) $p;return FileHash $p }

    $name=[string](Prop $recipe "name")
    try {
      $sourceType=([string](Prop $recipe "source_type" "github")).ToLowerInvariant()
      if($sourceType-eq"pypi"){
        $package=[string](Prop $recipe "package" $name)
        $metadata=Invoke-RestMethod ("https://pypi.org/pypi/{0}/json"-f$package)
        $version=[string]$metadata.info.version
        $assets=@($metadata.urls|ForEach-Object{[pscustomobject]@{id=$_.digests.sha256.Substring(0,16);name=$_.filename;browser_download_url=$_.url;digest="sha256:$($_.digests.sha256)";packagetype=$_.packagetype}})
        $sdist=@($assets|Where-Object packagetype -eq "sdist")|Select-Object -First 1
        if(-not$sdist){throw "No PyPI sdist."}
        $tag=$version;$sourceUrl=[string]$sdist.browser_download_url;$sourceHash=AssetHash $sdist
        $sourceExtract=([string]$sdist.name)-replace"(?i)(\.tar\.gz|\.tar\.bz2|\.zip)$",""
      }else{
        $repo=[string](Prop $recipe "repo")
        $release=Invoke-RestMethod ("https://api.github.com/repos/{0}/releases/latest"-f$repo) -Headers $headers
        $tag=[string]$release.tag_name
        $pattern=[string](Prop $recipe "version_regex" "(?<version>\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.-]+)?)")
        $m=[regex]::Match($tag,$pattern);if(-not$m.Success){throw "Tag '$tag' does not match version_regex."}
        $version=if($m.Groups["version"].Success){$m.Groups["version"].Value}else{$m.Value}
        $assets=@($release.assets)
        $escapedTag=[Uri]::EscapeDataString($tag)
        $sourceUrl="https://github.com/$repo/archive/refs/tags/$escapedTag.zip"
        $sourceHash=""
        $repoName=($repo-split"/")[-1];$sourceExtract="$repoName-$($tag-replace'/','-')"
      }

      $assetPattern=[string](Prop $recipe "asset_pattern" "")
      $primary=$null
      if($assetPattern){$primary=@($assets|Where-Object{$_.name-match$assetPattern})|Select-Object -First 1}
      if(-not$primary){
        $primary=@($assets|Where-Object{$_.name-match"(?i)(portable|universal|any|windows.*(x64|amd64)|\.ps1$|\.exe$|\.zip$)"}|Sort-Object{
          if($_.name-match"(?i)(portable|universal|any|\.ps1$)"){0}elseif($_.name-match"(?i)(windows|win).*(x64|amd64)"){1}else{2}
        })|Select-Object -First 1
      }

      $requested=([string](Prop $recipe "mode" "auto")).ToLowerInvariant()
      $policy=([string](Prop $recipe "platform_policy" "universal-first")).ToLowerInvariant()
      $hardware=[bool](Prop $recipe "hardware_sensitive" $false)
      $native=[bool](Prop $recipe "native_modules" $false)
      if($requested-ne"auto"){$mode=$requested;$reason="explicit:$requested"}
      elseif($policy-eq"force-local"-or$hardware){$mode="local";$reason=if($hardware){"hardware-sensitive"}else{"policy:force-local"}}
      elseif($primary-and$policy-eq"universal-first"){$mode="upstream";$reason="compatible-upstream-asset"}
      elseif($native){$mode="hybrid";$reason="portable-preparation-plus-native-completion"}
      else{$mode="cloud";$reason="portable-cloud-build"}
      if($mode-eq"upstream"-and-not$primary){throw "Upstream mode has no compatible asset."}

      $upstreamUrls=[Collections.Generic.List[string]]::new();$upstreamHashes=[Collections.Generic.List[string]]::new()
      if($mode-eq"upstream"){
        $selected=[Collections.Generic.List[object]]::new();$selected.Add($primary)
        foreach($extraPattern in @(Prop $recipe "extra_assets" @())){
          $extra=@($assets|Where-Object{$_.name-match[string]$extraPattern})|Select-Object -First 1
          if(-not$extra){throw "Missing extra asset '$extraPattern'."};$selected.Add($extra)
        }
        foreach($asset in $selected){$upstreamUrls.Add([string]$asset.browser_download_url);$upstreamHashes.Add((AssetHash $asset))}
      }

      $canonical=[ordered]@{engine=$engine;recipe=$recipe;source_type=$sourceType;version=$version;tag=$tag;mode=$mode}
      $fingerprint=TextHash ($canonical|ConvertTo-Json -Depth 20 -Compress)
      $artifactName="$name-$version-$($fingerprint.Substring(0,12))-windows-x64.7z"
      $releaseTag="$name-v$version"
      $published=$null
      if($mode-in@("cloud","hybrid")-and-not$force){
        try{$own=Invoke-RestMethod ("https://api.github.com/repos/{0}/releases/tags/{1}"-f$targetRepo,$releaseTag)-Headers $headers;$published=@($own.assets|Where-Object name -eq $artifactName)|Select-Object -First 1}catch{if($null-ne$_.Exception.Response-and$_.Exception.Response.StatusCode.value__-ne404){throw}}
      }
      $publishedHash=if($published){AssetHash $published}else{""}
      [pscustomobject]@{
        name=$name;version=$version;tag=$tag;source_type=$sourceType;mode=$mode;reason=$reason
        fingerprint=$fingerprint;artifact_name=$artifactName;release_tag=$releaseTag
        needs_build=($mode-in@("cloud","hybrid")-and-not$published)
        published_url=if($published){[string]$published.browser_download_url}else{""};published_hash=$publishedHash
        source_url=$sourceUrl;source_hash=$sourceHash;source_extract_dir=$sourceExtract
        upstream_urls=@($upstreamUrls);upstream_hashes=@($upstreamHashes)
        architectures=@(Prop $recipe "architectures" @("64bit"));recipe=$recipe;error=$null
      }
    }catch{[pscustomobject]@{name=$name;error=$_.Exception.Message}}
  } -ThrottleLimit $ThrottleLimit)
  $errors=@($results|Where-Object error)
  if($errors){throw (($errors|ForEach-Object{"[$($_.name)] $($_.error)"})-join[Environment]::NewLine)}
  return @($results|Sort-Object name)
}

function Expand-Source {
  param([object]$Plan,[string]$Destination)
  $extension=if($Plan.source_url-match"(?i)\.zip($|\?)"){".zip"}else{".archive"}
  $archive=Join-Path ([IO.Path]::GetFullPath($CacheDir)) ("source-"+$Plan.fingerprint+$extension)
  $null=Get-CachedFile $Plan.source_url $archive $Plan.source_hash
  $null=New-Item -ItemType Directory -Force -Path $Destination
  if($extension-eq".zip"){Expand-Archive -LiteralPath $archive -DestinationPath $Destination -Force}
  else{Invoke-Checked "tar" @("-xf",$archive,"-C",$Destination)}
  $root=Get-ChildItem -LiteralPath $Destination -Directory|Select-Object -First 1
  if($root){return $root.FullName}
  return $Destination
}

function Get-BuildType {
  param([object]$Plan,[string]$SourceRoot)
  $type=([string](Get-Prop $Plan.recipe "build_type" "auto")).ToLowerInvariant()
  if($type-ne"auto"){return $type}
  if(Test-Path (Join-Path $SourceRoot "pyproject.toml")){return "python"}
  if(Test-Path (Join-Path $SourceRoot "requirements.txt")){return "python"}
  if(Test-Path (Join-Path $SourceRoot "package.json")){return "node"}
  if(Test-Path (Join-Path $SourceRoot "Cargo.toml")){return "rust"}
  if(Test-Path (Join-Path $SourceRoot "go.mod")){return "go"}
  if(Get-ChildItem -LiteralPath $SourceRoot -Filter "*.ps1" -File|Select-Object -First 1){return "powershell"}
  throw "Cannot detect build_type for '$($Plan.name)'."
}

function Prepare-HybridPackage {
  param([object]$Plan,[string]$SourceRoot,[string]$PackageDir,[string]$BuildType)
  Copy-Item -LiteralPath (Join-Path $SourceRoot "*") -Destination $PackageDir -Recurse -Force
  Push-Location $PackageDir
  try{
    switch($BuildType){
      "python"{
        $wheelhouse=Join-Path $PackageDir ".meta\wheelhouse";$null=New-Item -ItemType Directory -Force -Path $wheelhouse
        if(Test-Path "requirements.txt"){Invoke-Checked "python" @("-m","pip","download","--disable-pip-version-check","--dest",$wheelhouse,"-r","requirements.txt")}
        Invoke-Checked "python" @("-m","pip","download","--disable-pip-version-check","--dest",$wheelhouse,"pyinstaller")
      }
      "node"{Invoke-Checked "corepack" @("enable");Invoke-Checked "pnpm" @("fetch","--prod","--frozen-lockfile")}
      "bun"{Invoke-Checked "bun" @("install","--frozen-lockfile","--ignore-scripts")}
      "go"{Invoke-Checked "go" @("mod","vendor")}
      "rust"{
        $vendor=Join-Path $PackageDir "vendor";Invoke-Checked "cargo" @("vendor",$vendor)
        $cargoDir=Join-Path $PackageDir ".cargo";$null=New-Item -ItemType Directory -Force -Path $cargoDir
        '[source.crates-io]'+'\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "vendor"'|Set-Content -LiteralPath (Join-Path $cargoDir "config.toml") -Encoding utf8
      }
      default{}
    }
  }finally{Pop-Location}
}

function Build-CloudPackage {
  param([object]$Plan,[string]$PackageDir,[string]$SourceRoot,[string]$BuildType)
  Push-Location $SourceRoot
  try{
    switch($BuildType){
      "python"{
        $entry=[string](Get-Prop $Plan.recipe "entrypoint" "")
        if(-not$entry){$entry=(Get-ChildItem -LiteralPath $SourceRoot -Filter "*.py" -File|Select-Object -First 1).Name}
        if(-not$entry){throw "Python entrypoint not found."}
        if(Test-Path "requirements.txt"){Invoke-Checked "python" @("-m","pip","install","--disable-pip-version-check","-r","requirements.txt")}
        Invoke-Checked "python" @("-m","PyInstaller","--noconfirm","--clean","--onefile","--name",$Plan.name,"--distpath",$PackageDir,$entry)
      }
      "go"{Invoke-Checked "go" @("build","-trimpath","-ldflags=-s -w","-o",(Join-Path $PackageDir "$($Plan.name).exe"),".")}
      "rust"{Invoke-Checked "cargo" @("build","--locked","--release");Get-ChildItem "target\release\*.exe"-File|Copy-Item -Destination $PackageDir}
      "node"{
        Invoke-Checked "corepack" @("enable");Invoke-Checked "pnpm" @("install","--frozen-lockfile");Invoke-Checked "pnpm" @("run","build")
        foreach($path in @("build","dist","drizzle","package.json","pnpm-lock.yaml")){if(Test-Path $path){Copy-Item $path -Destination $PackageDir -Recurse -Force}}
        Push-Location $PackageDir;try{if(Test-Path "pnpm-lock.yaml"){Invoke-Checked "pnpm" @("install","--prod","--frozen-lockfile")}}finally{Pop-Location}
        @("@echo off",'node "%~dp0build\server\index.js" %*')|Set-Content -LiteralPath (Join-Path $PackageDir "$($Plan.name).cmd") -Encoding ascii
      }
      "bun"{
        Invoke-Checked "bun" @("install","--frozen-lockfile");Invoke-Checked "bun" @("run","build")
        $out=[string](Get-Prop $Plan.recipe "output_path" "dist");if(-not(Test-Path $out)){throw "Missing Bun output '$out'."};Copy-Item $out -Destination $PackageDir -Recurse -Force
      }
      "powershell"{
        $entry=[string](Get-Prop $Plan.recipe "entrypoint" (Get-Prop $Plan.recipe "bin"));if(-not(Test-Path $entry)){throw "Missing PowerShell entrypoint '$entry'."};Copy-Item $entry -Destination $PackageDir
      }
      default{throw "Unsupported build_type '$BuildType'."}
    }
  }finally{Pop-Location}
}

function Invoke-BuildPhase {
  param([object[]]$Plans)
  $levels=Get-DependencyLevels @($Plans|ForEach-Object{$_.recipe})
  $byName=@{};foreach($plan in $Plans){$byName[$plan.name]=$plan}
  $stageRoot=[IO.Path]::GetFullPath($StageDir);$null=New-Item -ItemType Directory -Force -Path $stageRoot
  $all=[Collections.Generic.List[object]]::new()
  foreach($level in $levels){
    $levelPlans=@($level|ForEach-Object{$byName[$_]})
    $results=@($levelPlans|ForEach-Object -Parallel {
      $plan=$_;$stageRoot=$using:stageRoot;$cacheRoot=[IO.Path]::GetFullPath($using:CacheDir);$throttle=$using:ThrottleLimit
      function Prop{param([object]$o,[string]$n,$d=$null);$p=$o.PSObject.Properties[$n];if($null-eq$p-or$null-eq$p.Value){return $d};return $p.Value}
      function Hash{param([string]$p);$s=[IO.File]::OpenRead($p);try{return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($s)).ToLowerInvariant()}finally{$s.Dispose()}}
      function Cmd{param([string]$f,[string[]]$a);&$f @a 2>&1|Out-Host;if($LASTEXITCODE-ne0){throw "'$f' failed: $LASTEXITCODE"}}
      function Cache{param([string]$u,[string]$p,[string]$h="");if(Test-Path $p){$a=Hash $p;if(-not$h-or$a-eq$h){return $p};Remove-Item $p -Force};$null=New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($p));Invoke-WebRequest $u -OutFile $p -UseBasicParsing;if($h-and(Hash $p)-ne$h){throw "Hash mismatch"};return $p}
      $work=Join-Path $stageRoot ("work-"+$plan.name+"-"+$plan.fingerprint.Substring(0,8))
      try{
        $bootstrap=[bool](Prop $plan.recipe "toolchain" (Prop $plan.recipe "bootstrap" $false))
        $bootstrapPath=""
        if($bootstrap-and$plan.mode-eq"upstream"){
          $toolRoot=Join-Path $cacheRoot ("toolchain\"+$plan.name+"\"+$plan.version)
          $marker=Join-Path $toolRoot ".complete"
          if(-not(Test-Path $marker)){
            $null=New-Item -ItemType Directory -Force -Path $toolRoot
            $url=[string]$plan.upstream_urls[0];$hash=[string]$plan.upstream_hashes[0];$asset=Join-Path $cacheRoot ("tool-"+$hash)
            $null=Cache $url $asset $hash
            if($url-match"(?i)\.zip($|\?)"){Expand-Archive $asset $toolRoot -Force}elseif($url-match"(?i)\.7z($|\?)"){Cmd "7z" @("x","-y","-o$toolRoot",$asset)}else{Copy-Item $asset $toolRoot}
            Set-Content $marker $plan.version -Encoding ascii
          }
          $exe=[string](Prop $plan.recipe "bootstrap_exe" (Prop $plan.recipe "bin"))
          $found=Get-ChildItem $toolRoot -Filter $exe -File -Recurse|Select-Object -First 1;if(-not$found){throw "Tool '$exe' not found"}
          $bootstrapPath=$found.DirectoryName
        }
        if(-not$plan.needs_build){return [pscustomobject]@{name=$plan.name;status="reused";archive="";hash=$plan.published_hash;bootstrap_path=$bootstrapPath;error=$null}}
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        $sourceDir=Join-Path $work "source";$packageDir=Join-Path $work "package";$outputDir=Join-Path $stageRoot $plan.name
        $null=New-Item -ItemType Directory -Force -Path $sourceDir,$packageDir,$outputDir
        $sourceArchive=Join-Path $cacheRoot ("source-"+$plan.fingerprint)
        $null=Cache $plan.source_url $sourceArchive $plan.source_hash
        if($plan.source_url-match"(?i)\.zip($|\?)"){Expand-Archive $sourceArchive $sourceDir -Force}else{Cmd "tar" @("-xf",$sourceArchive,"-C",$sourceDir)}
        $root=Get-ChildItem $sourceDir -Directory|Select-Object -First 1;$sourceRoot=if($root){$root.FullName}else{$sourceDir}
        $type=([string](Prop $plan.recipe "build_type" "auto")).ToLowerInvariant()
        if($type-eq"auto"){$type=if(Test-Path (Join-Path $sourceRoot "package.json")){"node"}elseif(Test-Path(Join-Path $sourceRoot "Cargo.toml")){"rust"}elseif(Test-Path(Join-Path $sourceRoot "go.mod")){"go"}elseif((Test-Path(Join-Path $sourceRoot "pyproject.toml"))-or(Test-Path(Join-Path $sourceRoot "requirements.txt"))){"python"}else{"powershell"}}
        if($plan.mode-eq"hybrid"){
          Copy-Item (Join-Path $sourceRoot "*") $packageDir -Recurse -Force
          Push-Location $packageDir
          try{
            switch($type){
              "python"{$wheel=Join-Path $packageDir ".meta\wheelhouse";$null=New-Item -ItemType Directory -Force -Path $wheel;if(Test-Path"requirements.txt"){Cmd "python" @("-m","pip","download","--dest",$wheel,"-r","requirements.txt")};Cmd "python" @("-m","pip","download","--dest",$wheel,"pyinstaller")}
              "node"{Cmd "corepack" @("enable");Cmd "pnpm" @("fetch","--prod","--frozen-lockfile")}
              "bun"{Cmd "bun" @("install","--frozen-lockfile","--ignore-scripts")}
              "go"{Cmd "go" @("mod","vendor")}
              "rust"{Cmd "cargo" @("vendor",(Join-Path $packageDir "vendor"))}
            }
          }finally{Pop-Location}
        }else{
          Push-Location $sourceRoot
          try{
            switch($type){
              "python"{$entry=[string](Prop $plan.recipe "entrypoint" "");if(-not$entry){$entry=(Get-ChildItem *.py -File|Select-Object -First 1).Name};if(Test-Path"requirements.txt"){Cmd "python" @("-m","pip","install","-r","requirements.txt")};Cmd "python" @("-m","PyInstaller","--noconfirm","--clean","--onefile","--name",$plan.name,"--distpath",$packageDir,$entry)}
              "go"{Cmd "go" @("build","-trimpath","-ldflags=-s -w","-o",(Join-Path $packageDir "$($plan.name).exe"),".")}
              "rust"{Cmd "cargo" @("build","--locked","--release");Get-ChildItem "target\release\*.exe"-File|Copy-Item -Destination $packageDir}
              "node"{Cmd "corepack" @("enable");Cmd "pnpm" @("install","--frozen-lockfile");Cmd "pnpm" @("run","build");foreach($p in @("build","dist","drizzle","package.json","pnpm-lock.yaml")){if(Test-Path$p){Copy-Item $p $packageDir -Recurse -Force}};Push-Location $packageDir;try{if(Test-Path"pnpm-lock.yaml"){Cmd "pnpm" @("install","--prod","--frozen-lockfile")}}finally{Pop-Location};@("@echo off",'node "%~dp0build\server\index.js" %*')|Set-Content (Join-Path $packageDir "$($plan.name).cmd") -Encoding ascii}
              "bun"{Cmd "bun" @("install","--frozen-lockfile");Cmd "bun" @("run","build");$out=[string](Prop $plan.recipe "output_path" "dist");Copy-Item $out $packageDir -Recurse -Force}
              "powershell"{$entry=[string](Prop $plan.recipe "entrypoint" (Prop $plan.recipe "bin"));Copy-Item $entry $packageDir}
              default{throw "Unsupported build_type '$type'"}
            }
          }finally{Pop-Location}
        }
        Get-ChildItem $packageDir -Recurse -Force|Where-Object{$_.Name-match"(?i)^(test|tests|docs|__pycache__)$|\.(map|pdb|d\.ts|pyc)$"}|Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        if(-not(Get-ChildItem $packageDir -File -Recurse|Select-Object -First 1)){throw "Empty package"}
        $archive=Join-Path $outputDir $plan.artifact_name
        $level=[int](Prop $plan.recipe "compression_level" 7);$threads=[Math]::Max(1,[int]([Environment]::ProcessorCount/[Math]::Max(1,$throttle)))
        Cmd "7z" @("a","-t7z","-mx=$level","-m0=lzma2","-ms=on","-mqs=on","-mmt=$threads",$archive,(Join-Path $packageDir "*"))
        [pscustomobject]@{name=$plan.name;status="built";archive=$plan.artifact_name;hash=(Hash $archive);bootstrap_path=$bootstrapPath;error=$null}
      }catch{[pscustomobject]@{name=$plan.name;status="failed";archive="";hash="";bootstrap_path="";error=$_.Exception.Message}}
      finally{Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue}
    } -ThrottleLimit $ThrottleLimit)
    foreach($result in $results){
      $all.Add($result)
      if($result.bootstrap_path){$env:PATH="$($result.bootstrap_path);$env:PATH";if($env:GITHUB_PATH){Add-Content $env:GITHUB_PATH $result.bootstrap_path}}
    }
  }
  $errors=@($all|Where-Object error);if($errors){throw(($errors|ForEach-Object{"[$($_.name)] $($_.error)"})-join[Environment]::NewLine)}
  Write-Utf8Json (Join-Path $stageRoot "results.json") ([ordered]@{engine_version=$EngineVersion;results=@($all|Sort-Object name)})
}

function Get-LocalCommands {
  param([object]$Plan)
  $custom=@(Get-Prop $Plan.recipe "local_commands" @())
  if($custom.Count){return $custom}
  $type=([string](Get-Prop $Plan.recipe "build_type" "auto")).ToLowerInvariant()
  $name=[string]$Plan.name;$bin=[string](Get-Prop $Plan.recipe "bin" "")
  $offline=$Plan.mode-eq"hybrid"
  $commands=[Collections.Generic.List[string]]::new()
  $commands.Add('$ErrorActionPreference = "Stop"')
  $commands.Add('$jobs = [Math]::Max(1, [Environment]::ProcessorCount)')
  switch($type){
    "python"{
      $entry=[string](Get-Prop $Plan.recipe "entrypoint" "$name.py")
      $commands.Add('python -m venv "$dir\.meta\venv"')
      $pip='& "$dir\.meta\venv\Scripts\python.exe" -m pip install --disable-pip-version-check'
      if($offline){$pip+=' --no-index --find-links "$dir\.meta\wheelhouse"'}
      $commands.Add($pip+' pyinstaller')
      $commands.Add(($pip+' -r requirements.txt'))
      $commands.Add(('& "$dir\.meta\venv\Scripts\python.exe" -m PyInstaller --noconfirm --clean --onefile --name "{0}" --distpath "$dir" "{1}"' -f $name,$entry))
    }
    "go"{$vendor=if($offline){"-mod=vendor "}else{""};$commands.Add(('go build {0}-trimpath -ldflags="-s -w" -o "$dir\{1}.exe" .' -f $vendor,$name))}
    "rust"{
      $flag=if($offline){" --offline"}else{""};$commands.Add("cargo build --locked --release$flag")
      $output=[string](Get-Prop $Plan.recipe "local_output" "target\release\$name.exe")
      $commands.Add(('Copy-Item -LiteralPath "{0}" -Destination "$dir\{1}.exe" -Force' -f $output,$name))
    }
    "node"{
      $commands.Add("corepack enable");$install=if($offline){"pnpm install --offline --frozen-lockfile"}else{"pnpm install --frozen-lockfile"};$commands.Add($install);$commands.Add("pnpm run build")
      $commands.Add(('@("@echo off", ''node "%~dp0build\server\index.js" %*'') | Set-Content -LiteralPath "$dir\{0}.cmd" -Encoding ascii' -f $name))
    }
    "bun"{$commands.Add("bun install --frozen-lockfile");$commands.Add("bun run build")}
    "powershell"{}
    default{throw "Local/hybrid recipe '$name' requires build_type or local_commands."}
  }
  if($bin){$commands.Add(('if (-not (Test-Path -LiteralPath "$dir\{0}")) {{ throw "Expected output {0} was not produced." }}' -f $bin))}
  return @($commands)
}

function Get-ToolDepends {
  param([object]$Plan)
  $set=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($d in @(Get-Prop $Plan.recipe "depends" @())){$null=$set.Add([string]$d)}
  foreach($d in @(Get-Prop $Plan.recipe "tool_dependencies" @())){$null=$set.Add([string]$d)}
  if($Plan.mode-in@("local","hybrid")){
    $tool=switch(([string](Get-Prop $Plan.recipe "build_type" "")).ToLowerInvariant()){"python"{"python"};"go"{"go"};"rust"{"rust"};"node"{"nodejs"};"bun"{"bun"};default{$null}}
    if($tool){$null=$set.Add($tool)}
  }
  return @($set|Sort-Object)
}

function Invoke-FinalizePhase {
  param([object[]]$Plans)
  $stageResultsPath=Join-Path ([IO.Path]::GetFullPath($StageDir)) "results.json"
  $results=@{}
  if(Test-Path $stageResultsPath){foreach($r in @((Get-Content $stageResultsPath -Raw|ConvertFrom-Json).results)){$results[$r.name]=$r}}
  $headers=Get-Headers;$targetRepo=if($env:GITHUB_REPOSITORY){$env:GITHUB_REPOSITORY}else{"Anri2021/scoop-bucket"}
  $null=New-Item -ItemType Directory -Force -Path $BucketDir
  $lockPackages=[ordered]@{}
  foreach($plan in $Plans|Sort-Object name){
    $urls=@();$hashes=@();$extractDir=""
    if($plan.mode-eq"upstream"){$urls=@($plan.upstream_urls);$hashes=@($plan.upstream_hashes);$extractDir=[string](Get-Prop $plan.recipe "extract_dir" "")}
    elseif($plan.mode-eq"local"){$urls=@($plan.source_url);$hashes=@($plan.source_hash);$extractDir=[string]$plan.source_extract_dir}
    else{
      if($plan.needs_build){
        $result=$results[$plan.name];if(-not$result-or$result.status-ne"built"){throw "Missing build result for '$($plan.name)'."}
        $archive=Get-ChildItem -LiteralPath $StageDir -Filter $result.archive -File -Recurse|Select-Object -First 1;if(-not$archive){throw "Missing staged archive '$($result.archive)'."}
        if($NoPublish){$urls=@($archive.FullName)}
        else{
          $exists=$false;try{$null=Invoke-Checked "gh" @("release","view",$plan.release_tag,"--repo",$targetRepo);$exists=$true}catch{}
          if($exists){Invoke-Checked "gh" @("release","upload",$plan.release_tag,$archive.FullName,"--repo",$targetRepo,"--clobber")}
          else{Invoke-Checked "gh" @("release","create",$plan.release_tag,$archive.FullName,"--repo",$targetRepo,"--title","$($plan.name) $($plan.version)","--notes","Meta-Bucket build $($plan.fingerprint).")}
          $urls=@("https://github.com/$targetRepo/releases/download/$($plan.release_tag)/$($plan.artifact_name)")
        }
        $hashes=@($result.hash)
      }else{$urls=@($plan.published_url);$hashes=@($plan.published_hash)}
    }

    $download=[ordered]@{url=if($urls.Count-eq1){$urls[0]}else{$urls};hash=if($hashes.Count-eq1){$hashes[0]}else{$hashes}}
    if($extractDir){$download.extract_dir=$extractDir}
    $manifest=[ordered]@{version=$plan.version;description=[string](Get-Prop $plan.recipe "description");homepage=[string](Get-Prop $plan.recipe "homepage");license=[string](Get-Prop $plan.recipe "license")}
    $architectures=@($plan.architectures)
    if($architectures.Count-eq1-and$architectures[0]-eq"64bit"){$manifest.url=$download.url;$manifest.hash=$download.hash;if($extractDir){$manifest.extract_dir=$extractDir}}
    else{$manifest.architecture=[ordered]@{};foreach($arch in $architectures){$manifest.architecture[$arch]=$download}}
    $bin=Get-Prop $plan.recipe "bin";if($bin){$manifest.bin=$bin}
    $depends=@(Get-ToolDepends $plan);if($depends.Count){$manifest.depends=if($depends.Count-eq1){$depends[0]}else{$depends}}
    if($plan.mode-in@("local","hybrid")){$manifest.pre_install=Get-LocalCommands $plan}
    $persist=@(Get-Prop $plan.recipe "persist" @());if($persist.Count){$manifest.persist=if($persist.Count-eq1){$persist[0]}else{$persist}}
    $shortcuts=Get-Prop $plan.recipe "shortcuts";if($shortcuts){$manifest.shortcuts=$shortcuts}
    Write-Utf8Json (Join-Path $BucketDir "$($plan.name).json") $manifest 20
    $lockPackages[$plan.name]=[ordered]@{version=$plan.version;tag=$plan.tag;mode=$plan.mode;reason=$plan.reason;fingerprint=$plan.fingerprint;artifact=$plan.artifact_name}
  }
  $active=[Collections.Generic.HashSet[string]]::new([string[]]@($Plans.name),[StringComparer]::OrdinalIgnoreCase)
  Get-ChildItem $BucketDir -Filter "*.json" -File|Where-Object{-not$active.Contains($_.BaseName)}|Remove-Item -Force
  $recipesHash=Get-FileSha256 $RecipesPath
  Write-Utf8Json (Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($RecipesPath))) "recipes.lock.json") ([ordered]@{engine_version=$EngineVersion;recipes_sha256=$recipesHash;packages=$lockPackages}) 20
}

$RecipesPath=[IO.Path]::GetFullPath($RecipesPath)
$PlanPath=[IO.Path]::GetFullPath($PlanPath)
$StageDir=[IO.Path]::GetFullPath($StageDir)
$BucketDir=[IO.Path]::GetFullPath($BucketDir)
$CacheDir=[IO.Path]::GetFullPath($CacheDir)
if(-not(Test-Path $RecipesPath)){throw "Recipes file not found: $RecipesPath"}
$config=Get-Content $RecipesPath -Raw -Encoding utf8|ConvertFrom-Json
$recipes=@($config.recipes);Assert-Recipes $recipes
$targetRepository=if($env:GITHUB_REPOSITORY){$env:GITHUB_REPOSITORY}else{"Anri2021/scoop-bucket"}

if($Phase-in@("Plan","All")){
  $plans=Resolve-Plans $recipes $targetRepository $EngineVersion -Force:$ForceRebuild
  $planDocument=[ordered]@{engine_version=$EngineVersion;recipes_sha256=(Get-FileSha256 $RecipesPath);packages=$plans}
  Write-Utf8Json $PlanPath $planDocument 30
  $plans|Format-Table name,version,mode,reason,needs_build -AutoSize
  if($ValidateOnly){exit 0}
}
if($Phase-in@("Build","Finalize")){
  if(-not(Test-Path $PlanPath)){throw "Plan not found: $PlanPath"}
  $planDocument=Get-Content $PlanPath -Raw -Encoding utf8|ConvertFrom-Json
  if($planDocument.engine_version-ne$EngineVersion){throw "Plan engine version mismatch."}
  $plans=@($planDocument.packages)
}
if($Phase-in@("Build","All")){Invoke-BuildPhase $plans}
if($Phase-in@("Finalize","All")){Invoke-FinalizePhase $plans}
