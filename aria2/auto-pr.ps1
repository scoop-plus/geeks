<#
.SYNOPSIS
    Updates manifests and pushes them or creates pull-requests (with aria2 download support).
#>
param(
    [ValidateScript( {
            if ($_ -and !($_ -match '^[^/]+/[^/]+:[^:]+$')) {
                throw 'Upstream must be in this format: <user>/<repo>:<branch>'
            }
            $true
        })]
    [String] $Upstream,
    [String] $OriginBranch,
    [String] $App = '*',
    [String] $CommitMessageFormat = '<app>: Update to version <version>',
    [ValidateScript( {
            if ($_ -and !(Test-Path $_ -Type Container)) {
                throw "$_ is not a directory!"
            } else {
                $true
            }
        })]
    [String] $Dir,
    [Switch] $Push,
    [Switch] $Request,
    [Switch] $Help,
    [string[]] $SpecialSnowflakes,
    [Switch] $SkipUpdated,
    [Switch] $ThrowError
)

if (!$env:SCOOP_HOME) { $env:SCOOP_HOME = Convert-Path (scoop prefix scoop) }

. "$env:SCOOP_HOME\lib\core.ps1"
. "$env:SCOOP_HOME\lib\manifest.ps1"
. "$env:SCOOP_HOME\lib\json.ps1"
. "$PSScriptRoot\download.ps1"

if ($App -ne '*' -and (Test-Path $App -PathType Leaf)) {
    $Dir = Split-Path $App
} elseif ($Dir) {
    $Dir = Convert-Path $Dir
} else {
    $Dir = Convert-Path "$PSScriptRoot\..\bucket"
}

if ((!$Push -and !$Request) -or $Help) {
    Write-Host @'
Usage: auto-pr.ps1 [OPTION]

Mandatory options:
  -p,  -push                       push updates directly to 'origin branch'
  -r,  -request                    create pull-requests on 'upstream branch' for each update

Optional options:
  -u,  -upstream                   upstream repository with target branch
  -o,  -originbranch               origin (local) branch name
  -h,  -help
'@
    exit 0
}

if ($IsLinux -or $IsMacOS) {
    if (!(which hub)) {
        Write-Host "Please install hub ('brew install hub' or visit: https://hub.github.com/)" -ForegroundColor Yellow
        exit 1
    }
} else {
    if (!(scoop which hub)) {
        Write-Host "Please install hub 'scoop install hub'" -ForegroundColor Yellow
        exit 1
    }
}

if (!$OriginBranch) {
    $currentBranch = (git branch --show-current 2>$null)
    $OriginBranch = if ($currentBranch) { $currentBranch.Trim() } else { 'main' }
}

if ($Request -and !$Upstream) {
    $remoteUrl = (git config --get remote.upstream.url 2>$null)
    if (!$remoteUrl) {
        $remoteUrl = (git config --get remote.origin.url 2>$null)
    }

    if ($remoteUrl -and ($remoteUrl -match '[:/]([^/:]+)/([^/:]+?)(?:\.git)?$')) {
        $Upstream = "$($Matches[1])/$($Matches[2]):$OriginBranch"
        Write-Host "Auto-detected upstream: $Upstream" -ForegroundColor DarkCyan
    } else {
        abort "Please specify -Upstream in format '<user>/<repo>:<branch>' when using -Request!"
    }
}

function execute($cmd, [ScriptBlock] $onError) {
    Write-Host $cmd -ForegroundColor Green
    $output = Invoke-Command ([scriptblock]::Create($cmd))

    if ($LASTEXITCODE -gt 0) {
        if ($onError) { Invoke-Command $onError }
        abort "^^^ Error! See above ^^^ (last command: $cmd)"
    }

    return $output
}

function pull_requests($json, [String] $app, [String] $upstream, [String] $manifest, [String] $commitMessage) {
    $version = $json.version
    $homepage = $json.homepage
    $branch = "manifest/$app-$version"

    execute "hub checkout $OriginBranch"
    Write-Host "hub rev-parse --verify $branch" -ForegroundColor Green
    hub rev-parse --verify $branch

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Skipping update $app ($version) ..." -ForegroundColor Yellow
        return
    }

    Write-Host "Creating update $app ($version) ..." -ForegroundColor DarkCyan
    execute "hub checkout -b $branch"
    execute "hub add $manifest"
    execute "hub commit -m '$commitMessage'"
    Write-Host "Pushing update $app ($version) ..." -ForegroundColor DarkCyan
    execute "hub push origin $branch"

    if ($LASTEXITCODE -gt 0) {
        error "Push failed! (hub push origin $branch)"
        execute 'hub reset'
        return
    }

    Start-Sleep 1
    Write-Host "Pull-Request update $app ($version) ..." -ForegroundColor DarkCyan
    Write-Host "hub pull-request -m '<msg>' -b '$upstream' -h '$branch'" -ForegroundColor Green

    $msg = @"
$commitMessage

Hello lovely humans,
a new version of [$app]($homepage) is available.

| State       | Update :rocket: |
| :---------- | :-------------- |
| New version | $version        |
"@

    hub pull-request -m "$msg" -b "$upstream" -h "$branch"
    if ($LASTEXITCODE -gt 0) {
        execute 'hub reset'
        abort "Pull Request failed! (hub pull-request -m '$commitMessage' -b '$upstream' -h '$branch')"
    }
}

Write-Host 'Updating ...' -ForegroundColor DarkCyan
if ($Push) {
    execute "hub pull origin $OriginBranch"
    execute "hub checkout $OriginBranch"
} else {
    execute "hub pull upstream $OriginBranch"
    execute "hub push origin $OriginBranch"
}

. "$PSScriptRoot\checkver.ps1" -App $App -Dir $Dir -Update -SkipUpdated:$SkipUpdated -ThrowError:$ThrowError
if ($SpecialSnowflakes) {
    Write-Host "Forcing update on our special snowflakes: $($SpecialSnowflakes -join ',')" -ForegroundColor DarkCyan
    $SpecialSnowflakes -split ',' | ForEach-Object {
        . "$PSScriptRoot\checkver.ps1" $_ -Dir $Dir -ForceUpdate -ThrowError:$ThrowError
    }
}

hub diff --name-only | ForEach-Object {
    $manifest = $_
    if (!$manifest.EndsWith('.json')) {
        return
    }

    $app = ([System.IO.Path]::GetFileNameWithoutExtension($manifest))

    $formatjson = "$env:SCOOP_HOME\bin\formatjson.ps1"
    if (Test-Path $formatjson) {
        & $formatjson $app -Dir $Dir | Out-Null
    }

    $json = parse_json $manifest
    if (!$json.version) {
        error "Invalid manifest: $manifest ..."
        return
    }
    $version = $json.version
    $CommitMessage = $CommitMessageFormat -replace '<app>', $app -replace '<version>', $version
    if ($Push) {
        Write-Host "Creating update $app ($version) ..." -ForegroundColor DarkCyan
        execute "hub add $manifest"

        # detect if file was staged, because it's not when only LF or CRLF have changed
        $status = execute 'hub status --porcelain -uno'
        $status = $status | Where-Object { $_ -match "M\s{2}.*$app.json" }
        if ($status -and $status.StartsWith('M  ') -and $status.EndsWith("$app.json")) {
            execute "hub commit -m '$CommitMessage'"
        } else {
            Write-Host "Skipping $app because only LF/CRLF changes were detected ..." -ForegroundColor Yellow
        }
    } else {
        pull_requests $json $app $Upstream $manifest $CommitMessage
    }
}

if ($Push) {
    Write-Host 'Rebasing local branch before push ...' -ForegroundColor DarkCyan
    execute "hub pull --rebase --autostash origin $OriginBranch" { hub rebase --abort 2>$null; hub reset --hard }
    Write-Host 'Pushing updates ...' -ForegroundColor DarkCyan
    execute "hub push origin $OriginBranch"
} else {
    Write-Host "Returning to $OriginBranch branch and removing unstaged files ..." -ForegroundColor DarkCyan
    execute "hub checkout -f $OriginBranch"
}

execute 'hub reset --hard'
