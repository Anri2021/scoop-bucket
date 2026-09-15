[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent))

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
  param([bool]$Condition,[string]$Message)
  if(-not $Condition){throw "Assertion failed: $Message"}
}

$sourceRecipesPath=Join-Path $RepositoryRoot "recipes.json"
$recipesPath=$sourceRecipesPath
$schemaPath=Join-Path $RepositoryRoot "schemas/recipes.schema.json"
$enginePath=Join-Path $RepositoryRoot "scripts/generate-bucket.ps1"
$engineSha=(Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash.ToLowerInvariant()
$workflowPath=Join-Path $RepositoryRoot ".github/workflows/autoupdate.yml"
$workflowSha=(Get-FileHash -LiteralPath $workflowPath -Algorithm SHA256).Hash.ToLowerInvariant()
$pipelineBytes=[Text.Encoding]::UTF8.GetBytes("$engineSha`n$workflowSha")
$pipelineSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($pipelineBytes)).ToLowerInvariant()
$recipesJson=Get-Content $recipesPath -Raw -Encoding utf8
Assert-True ($recipesJson|Test-Json -SchemaFile $schemaPath) "recipes.json must match its schema"

$temp=Join-Path ([IO.Path]::GetTempPath()) ("meta-bucket-tests-"+[Guid]::NewGuid().ToString("N"))
$bucket=Join-Path $temp "bucket"
$stage=Join-Path $temp "stage"
$plan=Join-Path $temp "plan.json"
$null=New-Item -ItemType Directory -Force -Path $stage
$recipesPath=Join-Path $temp "recipes.json"
Copy-Item -LiteralPath $sourceRecipesPath -Destination $recipesPath
try{
  $hash="0"*64
  $plans=@(
    [ordered]@{
      name="fixture-upstream";version="1.0.0";tag="v1.0.0";source_type="github";mode="upstream";reason="test"
      fingerprint=("1"*64);artifact_name="unused.7z";release_tag="fixture-v1.0.0";needs_build=$false
      published_url="";published_hash="";source_url="https://example.invalid/source.zip";source_hash=$hash;source_extract_dir="fixture-1.0.0"
      upstream_urls=@("https://example.invalid/tool.zip");upstream_hashes=@($hash);architectures=@("64bit")
      recipe=[ordered]@{name="fixture-upstream";description="fixture";homepage="https://example.invalid";license="MIT";source_type="github";repo="owner/repo";mode="upstream";architectures=@("64bit");bin="tool.exe";toolchain=$true}
    },
    [ordered]@{
      name="fixture-local";version="1.0.0";tag="v1.0.0";source_type="github";mode="local";reason="hardware-sensitive"
      fingerprint=("2"*64);artifact_name="unused.7z";release_tag="fixture-v1.0.0";needs_build=$false
      published_url="";published_hash="";source_url="https://example.invalid/source.zip";source_hash=$hash;source_extract_dir="fixture-1.0.0"
      upstream_urls=@();upstream_hashes=@();architectures=@("64bit","arm64")
      recipe=[ordered]@{name="fixture-local";description="fixture";homepage="https://example.invalid";license="MIT";source_type="github";repo="owner/repo";mode="local";platform_policy="force-local";architectures=@("64bit","arm64");build_type="go";bin="fixture-local.exe";tool_dependencies=@("fixture-upstream")}
    },
    [ordered]@{
      name="fixture-hybrid";version="1.0.0";tag="v1.0.0";source_type="github";mode="hybrid";reason="native-modules"
      fingerprint=("3"*64);artifact_name="fixture-hybrid.7z";release_tag="fixture-v1.0.0";needs_build=$false
      published_url="https://example.invalid/hybrid.7z";published_hash=$hash;source_url="https://example.invalid/source.zip";source_hash=$hash;source_extract_dir="fixture-1.0.0"
      upstream_urls=@();upstream_hashes=@();architectures=@("64bit")
      recipe=[ordered]@{name="fixture-hybrid";description="fixture";homepage="https://example.invalid";license="MIT";source_type="github";repo="owner/repo";mode="hybrid";architectures=@("64bit");build_type="rust";bin="fixture-hybrid.exe";tool_dependencies=@("fixture-upstream")}
    }
  )
  $document=[ordered]@{engine_version="4.0";engine_sha256=$engineSha;pipeline_sha256=$pipelineSha;recipes_sha256=$hash;packages=$plans}
  $document|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $plan -Encoding utf8

  $testCache=Join-Path $temp "cache"
  & $enginePath -Phase Build -RecipesPath $recipesPath -PlanPath $plan -StageDir $stage -CacheDir $testCache
  $buildResults=@((Get-Content (Join-Path $stage "results.json") -Raw|ConvertFrom-Json).results)
  Assert-True (@($buildResults|Where-Object status -ne "reused").Count-eq0) "unchanged packages must not rebuild"
  Assert-True (-not(Test-Path (Join-Path $testCache "toolchain"))) "unused toolchains must not be downloaded"

  & $enginePath -Phase Finalize -RecipesPath $recipesPath -PlanPath $plan -StageDir $stage -BucketDir $bucket -NoPublish

  $local=Get-Content (Join-Path $bucket "fixture-local.json") -Raw|ConvertFrom-Json
  $hybrid=Get-Content (Join-Path $bucket "fixture-hybrid.json") -Raw|ConvertFrom-Json
  $upstream=Get-Content (Join-Path $bucket "fixture-upstream.json") -Raw|ConvertFrom-Json
  Assert-True ($null-ne$local.architecture.arm64) "local manifest must include arm64"
  Assert-True (@($local.pre_install).Count-ge3) "local manifest must carry an automatic build script"
  Assert-True (@($local.depends)-contains"go") "local Go build must depend on Go"
  Assert-True (@($local.depends)-contains"fixture-upstream") "tool dependency must be preserved"
  Assert-True (@($hybrid.pre_install).Count-ge3) "hybrid manifest must complete locally"
  Assert-True ($upstream.url-eq"https://example.invalid/tool.zip") "upstream must remain pass-through"
  Assert-True ((Get-Content $enginePath -Raw)-match'windows-x64\.zip') "cloud packages must use Scoop-compatible ZIP archives"

  $generatedLock=Join-Path (Split-Path $recipesPath -Parent) "recipes.lock.json"
  $first=(Get-FileHash $generatedLock -Algorithm SHA256).Hash
  & $enginePath -Phase Finalize -RecipesPath $recipesPath -PlanPath $plan -StageDir $stage -BucketDir $bucket -NoPublish
  $second=(Get-FileHash $generatedLock -Algorithm SHA256).Hash
  Assert-True ($first-eq$second) "lock file must be deterministic"
  Remove-Item $generatedLock -Force

  $cycleRecipes=Join-Path $temp "cycle.json"
  '{"recipes":[{"name":"a","description":"a","homepage":"https://example.invalid","license":"MIT","repo":"o/r","tool_dependencies":["b"]},{"name":"b","description":"b","homepage":"https://example.invalid","license":"MIT","repo":"o/r","tool_dependencies":["a"]}]}'|Set-Content $cycleRecipes -Encoding utf8
  $cycleRejected=$false
  try { & $enginePath -Phase Plan -ValidateOnly -RecipesPath $cycleRecipes -PlanPath (Join-Path $temp "cycle-plan.json") 2>$null }
  catch { $cycleRejected=$true }
  Assert-True $cycleRejected "toolchain cycles must be rejected"
}finally{
  if(Test-Path $temp){Remove-Item $temp -Recurse -Force}
}
Write-Host "Meta-Bucket contract tests passed." -ForegroundColor Green
