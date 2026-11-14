param(
    # overwrite upstream param
    [String]$upstream = "<username>/<bucketname>:main"
)

if (!$env:SCOOP_HOME) { $env:SCOOP_HOME = Convert-Path (scoop prefix scoop) }
$aria2_autopr = "$PSScriptRoot/../aria2/auto-pr.ps1"
$autopr = if (Test-Path $aria2_autopr) { $aria2_autopr } else { "$env:SCOOP_HOME/bin/auto-pr.ps1" }
$dir = "$PSScriptRoot/../bucket" # checks the parent dir
& $autopr -Dir $dir -OriginBranch main -Upstream $Upstream @Args
