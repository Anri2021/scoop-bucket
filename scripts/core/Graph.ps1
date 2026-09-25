<#
.SYNOPSIS
  Recipe validation and DAG dependency level resolution.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
