<#
.SYNOPSIS
    Check if ALL urls inside manifest have correct hashes (with aria2 download support).
#>
param(
    [String] $App = '*',
    [ValidateScript( {
        if ($_ -and !(Test-Path $_ -Type Container)) {
            throw "$_ is not a directory!"
        } else {
            $true
        }
    })]
    [String] $Dir,
    [Switch] $Update,
    [Switch] $ForceUpdate,
    [Switch] $SkipCorrect,
    [Alias('k')]
    [Switch] $UseCache
)

if (!$env:SCOOP_HOME) { $env:SCOOP_HOME = Convert-Path (scoop prefix scoop) }

. "$env:SCOOP_HOME\lib\core.ps1"
. "$env:SCOOP_HOME\lib\manifest.ps1"
. "$env:SCOOP_HOME\lib\buckets.ps1"
. "$env:SCOOP_HOME\lib\autoupdate.ps1"
. "$env:SCOOP_HOME\lib\json.ps1"
. "$env:SCOOP_HOME\lib\versions.ps1"
. "$env:SCOOP_HOME\lib\download.ps1"
. "$PSScriptRoot\download.ps1"

if ($Dir) {
    $Dir = Convert-Path $Dir
} else {
    $Dir = Convert-Path "$PSScriptRoot\..\bucket"
}

if ($ForceUpdate) { $Update = $true }
# Cleanup
if (!$UseCache) { Remove-Item "$cachedir\*HASH_CHECK*" -Force -ErrorAction SilentlyContinue }

function err ([String] $name, [String[]] $message) {
    Write-Host "$name`: " -ForegroundColor Red -NoNewline
    Write-Host ($message -join "`r`n") -ForegroundColor Red
}

$MANIFESTS = @()
foreach ($single in Get-ChildItem $Dir -Filter "$App.json" -Recurse) {
    $name = $single.BaseName
    $file = $single.FullName
    $manifest = parse_json $file

    # Skip nightly manifests, since their hash validation is skipped
    if ($manifest.version -eq 'nightly') { continue }

    $urls = @()
    $hashes = @()

    if ($manifest.url) {
        $manifest.url | ForEach-Object { $urls += $_ }
        $manifest.hash | ForEach-Object { $hashes += $_ }
    } elseif ($manifest.architecture) {
        # First handle 64bit
        script:url $manifest '64bit' | ForEach-Object { $urls += $_ }
        hash $manifest '64bit' | ForEach-Object { $hashes += $_ }
        script:url $manifest '32bit' | ForEach-Object { $urls += $_ }
        hash $manifest '32bit' | ForEach-Object { $hashes += $_ }
        script:url $manifest 'arm64' | ForEach-Object { $urls += $_ }
        hash $manifest 'arm64' | ForEach-Object { $hashes += $_ }
    } else {
        err $name 'Manifest does not contain URL property.'
        continue
    }

    # Number of URLS and Hashes is different
    if ($urls.Length -ne $hashes.Length) {
        err $name 'URLS and hashes count mismatch.'
        continue
    }

    $MANIFESTS += @{
        app      = $name
        file     = $file
        manifest = $manifest
        urls     = $urls
        hashes   = $hashes
    }
}

# clear any existing events
Get-Event | ForEach-Object { Remove-Event $_.SourceIdentifier }

foreach ($current in $MANIFESTS) {
    $count = 0
    # Array of indexes mismatched hashes.
    $mismatched = @()
    # Array of computed hashes
    $actuals = @()

    $current.urls | ForEach-Object {
        $algorithm, $expected = get_hash $current.hashes[$count]
        if ($UseCache) {
            $version = $current.manifest.version
        } else {
            $version = 'HASH_CHECK'
        }

        Invoke-CachedDownload $current.app $version $_ $null $null -use_cache:$UseCache

        $to_check = cache_path $current.app $version $_
        $actual_hash = (Get-FileHash -Path $to_check -Algorithm $algorithm).Hash.ToLower()

        # Append type of algorithm to both expected and actual if it's not sha256
        if ($algorithm -ne 'sha256') {
            $actual_hash = "$algorithm`:$actual_hash"
            $expected = "$algorithm`:$expected"
        }

        $actuals += $actual_hash
        if ($actual_hash -ne $expected) {
            $mismatched += $count
        }
        $count++
    }

    if ($mismatched.Length -eq 0 ) {
        if (!$SkipCorrect) {
            Write-Host "$($current.app): " -NoNewline
            Write-Host 'OK' -ForegroundColor Green
        }
    } else {
        Write-Host "$($current.app): " -NoNewline
        Write-Host 'Mismatch found ' -ForegroundColor Red
        $mismatched | ForEach-Object {
            $file = cache_path $current.app $version $current.urls[$_]
            Write-Host "`tURL:`t`t$($current.urls[$_])"
            if (Test-Path $file) {
                Write-Host "`tFirst bytes:`t$((get_magic_bytes_pretty $file ' ').ToUpper())"
            }
            Write-Host "`tExpected:`t$($current.hashes[$_])" -ForegroundColor Green
            Write-Host "`tActual:`t`t$($actuals[$_])" -ForegroundColor Red
        }
    }

    if ($Update) {
        if ($current.manifest.url -and $current.manifest.hash) {
            $current.manifest.hash = $actuals
        } else {
            $platforms = ($current.manifest.architecture | Get-Member -MemberType NoteProperty).Name
            $64bit_count = 0
            $32bit_count = 0
            $arm64_count = 0

            if ($platforms.Contains('64bit')) {
                $64bit_count = $current.manifest.architecture.'64bit'.hash.Count
                $current.manifest.architecture.'64bit'.hash = $actuals[0..($64bit_count - 1)]
            }
            if ($platforms.Contains('32bit')) {
                $32bit_count = $current.manifest.architecture.'32bit'.hash.Count
                $current.manifest.architecture.'32bit'.hash = $actuals[($64bit_count)..($64bit_count + $32bit_count - 1)]
            }
            if ($platforms.Contains('arm64')) {
                $arm64_count = $current.manifest.architecture.'arm64'.hash.Count
                $current.manifest.architecture.'arm64'.hash = $actuals[($64bit_count + $32bit_count)..($64bit_count + $32bit_count + $arm64_count - 1)]
            }
        }

        Write-Host "Writing updated $($current.app) manifest" -ForegroundColor DarkGreen

        $current.manifest = $current.manifest | ConvertToPrettyJson
        $path = Convert-Path $current.file
        [System.IO.File]::WriteAllLines($path, $current.manifest)
    }
}
