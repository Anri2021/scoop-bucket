<#
.SYNOPSIS
  Shared utilities for Meta-Bucket engine, planners, and builders.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-Prop {
  param([object]$Object, [string]$Name, $Default = $null)
  if ($null -eq $Object) { return $Default }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $Default }
  return $property.Value
}

function Write-Utf8Json {
  param([string]$Path, [object]$Value, [int]$Depth = 20)
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
  $stream = [System.IO.File]::OpenRead($Path)
  try {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
  }
  finally {
    $stream.Dispose()
  }
}

function Invoke-Checked {
  param([string]$File, [string[]]$Arguments)
  $output = & $File @Arguments 2>&1
  $output | Out-Host
  if ($LASTEXITCODE -ne 0) {
    $details = ($output | Select-Object -Last 10) -join "`n"
    throw "'$File' exited with code $LASTEXITCODE:`n$details"
  }
}

function Get-CachedFile {
  param([string]$Url, [string]$Path, [string]$ExpectedHash = "")
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $actual = Get-FileSha256 $Path
    if (-not $ExpectedHash -or $actual -eq $ExpectedHash) { return $Path }
    Remove-Item -LiteralPath $Path -Force
  }
  $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
  $null = New-Item -ItemType Directory -Force -Path $parent
  Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
  $actual = Get-FileSha256 $Path
  if ($ExpectedHash -and $actual -ne $ExpectedHash) {
    Remove-Item -LiteralPath $Path -Force
    throw "SHA256 mismatch for $Url"
  }
  return $Path
}

function Get-BuilderSha256 {
  param([string]$BuildType, [string]$BuildersDir)
  $builderPath = Join-Path $BuildersDir "$BuildType.ps1"
  if (Test-Path -LiteralPath $builderPath) {
    return (Get-FileSha256 $builderPath)
  }
  return (Get-TextSha256 "fallback-$BuildType")
}
