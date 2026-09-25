[CmdletBinding()]
param($Plan, $SourceRoot, $PackageDir, $CacheRoot)


  $entry = [string](Get-Prop $Plan.recipe "entrypoint" "")
  if (-not $entry -or -not (Test-Path $entry)) {
    if (Test-Path "scapy/main.py") { $entry = "scapy/main.py" }
    else { $entry = (Get-ChildItem *.py -File | Select-Object -First 1).Name }
  }
  Copy-Item -Path "*.py" -Destination $PackageDir -Force -ErrorAction SilentlyContinue
  if (Test-Path $Plan.name) { Copy-Item -Path $Plan.name -Destination $PackageDir -Recurse -Force }
  $libDir = Join-Path $PackageDir "lib"
  if (Test-Path "requirements.txt") {
    $null = New-Item -ItemType Directory -Force -Path $libDir
    if (Get-Command uv -ErrorAction SilentlyContinue) {
      Invoke-Checked "uv" @("pip", "install", "--target", $libDir, "-r", "requirements.txt")
    } else {
      Invoke-Checked "python" @("-m", "pip", "install", "--disable-pip-version-check", "--target", $libDir, "-r", "requirements.txt")
    }
  }
  Write-CmdShim -Path (Join-Path $PackageDir "$($Plan.name).cmd") -Command ('python "%~dp0{0}" %*' -f ($entry -replace '/', '\')) -PreCommand 'set "PYTHONPATH=%~dp0lib;%PYTHONPATH%"'

