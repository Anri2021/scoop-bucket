[CmdletBinding()]
param($Plan, $SourceRoot, $PackageDir, $CacheRoot)

Push-Location $SourceRoot
try {
  $entry = [string](Get-Prop $Plan.recipe "entrypoint" ".")
  if ($entry -and -not ($entry.StartsWith(".") -or $entry.StartsWith("/"))) { $entry = "./$entry" }
  $useCgo = [bool](Get-Prop $Plan.recipe "cgo" $false)
  $customArgs = @(Get-Prop $Plan.recipe "build_args" @())
  $ldFlags = if ($useCgo) { "-linkmode external -extldflags '-static' -s -w" } else { "-s -w" }
  $oldCgo = $env:CGO_ENABLED
  $env:CGO_ENABLED = if ($useCgo) { "1" } else { "0" }
  if ($useCgo -and -not (Get-Command gcc -ErrorAction SilentlyContinue)) {
    if (Test-Path "C:\msys64\mingw64\bin\gcc.exe") {
      $env:PATH = "C:\msys64\mingw64\bin;$env:PATH"
    } else {
      throw "CGO is enabled for $($Plan.name) but GCC compiler was not found."
    }
  }
  try {
    Invoke-Checked "go" (@("build", "-trimpath", "-ldflags=$ldFlags") + $customArgs + @("-o", (Join-Path $PackageDir "$($Plan.name).exe"), $entry))
  } finally {
    $env:CGO_ENABLED = $oldCgo
  }
} finally {
  Pop-Location
}
