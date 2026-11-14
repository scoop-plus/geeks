param(
    [String] $Upstream,
    [String] $OriginBranch
)

if (!$env:SCOOP_HOME) { $env:SCOOP_HOME = Convert-Path (scoop prefix scoop) }
$aria2_autopr = "$PSScriptRoot/../aria2/auto-pr.ps1"
$autopr = if (Test-Path $aria2_autopr) { $aria2_autopr } else { "$env:SCOOP_HOME/bin/auto-pr.ps1" }
$dir = "$PSScriptRoot/../bucket" # checks the parent dir

$params = @{
    Dir = $dir
}
if ($Upstream) { $params['Upstream'] = $Upstream }
if ($OriginBranch) { $params['OriginBranch'] = $OriginBranch }

& $autopr @params @Args
