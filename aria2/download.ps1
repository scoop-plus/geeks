if (!$env:SCOOP_HOME) { $env:SCOOP_HOME = Convert-Path (scoop prefix scoop) }

# Override Scoop's Start-Download / Invoke-CachedDownload to use aria2 when available in the system
function global:Invoke-Aria2StartDownload($url, $to, $cookies) {
    $aria2c = $null
    if (Get-Command Test-Aria2Enabled -ErrorAction SilentlyContinue) {
        if (Test-Aria2Enabled) {
            $aria2c = Get-HelperPath -Helper Aria2
        }
    }
    if (!$aria2c) {
        $aria2Enabled = if (Get-Command get_config -ErrorAction SilentlyContinue) { get_config 'aria2-enabled' $true } else { $true }
        if ($aria2Enabled) {
            $cmd = Get-Command aria2c -ErrorAction SilentlyContinue
            if ($cmd) { $aria2c = $cmd.Source }
        }
    }

    if ($aria2c) {
        try {
            $tryUrl = if (Get-Command handle_special_urls -ErrorAction SilentlyContinue) { handle_special_urls $url } else { $url }
        } catch {
            $tryUrl = $url
        }
        $reqUrl = ($tryUrl -split '#')[0]
        $targetDir = Split-Path $to -Parent
        $targetFile = Split-Path $to -Leaf

        $userAgent = if (Get-Command Get-UserAgent -ErrorAction SilentlyContinue) { Get-UserAgent } else { 'Scoop/1.0' }
        $retryWait = if (Get-Command get_config -ErrorAction SilentlyContinue) { get_config 'aria2-retry-wait' 2 } else { 2 }
        $split = if (Get-Command get_config -ErrorAction SilentlyContinue) { get_config 'aria2-split' 5 } else { 5 }
        $maxConn = if (Get-Command get_config -ErrorAction SilentlyContinue) { get_config 'aria2-max-connection-per-server' 5 } else { 5 }
        $minSplit = if (Get-Command get_config -ErrorAction SilentlyContinue) { get_config 'aria2-min-split-size' '5M' } else { '5M' }

        $options = @(
            $reqUrl
            "--dir=$targetDir"
            "--out=$targetFile"
            "--user-agent=$userAgent"
            '--allow-overwrite=true'
            '--auto-file-renaming=false'
            "--retry-wait=$retryWait"
            "--split=$split"
            "--max-connection-per-server=$maxConn"
            "--min-split-size=$minSplit"
            '--console-log-level=warn'
            '--enable-color=false'
            '--no-conf=true'
            '--follow-metalink=true'
            '--metalink-preferred-protocol=https'
            '--min-tls-version=TLSv1.2'
            "--stop-with-process=$PID"
            '--continue=true'
            '--summary-interval=0'
            '--auto-save-interval=1'
        )

        if (-not ($url -match 'sourceforge\.net' -or $url -match 'portableapps\.com')) {
            if (Get-Command strip_filename -ErrorAction SilentlyContinue) {
                $options += "--referer=$(strip_filename $url)"
            }
        }

        if ($cookies -and (Get-Command cookie_header -ErrorAction SilentlyContinue)) {
            $options += "--header=Cookie: $(cookie_header $cookies)"
        }

        if ($reqUrl -match '^https://api\.github\.com/repos' -and (Get-Command Get-GitHubToken -ErrorAction SilentlyContinue)) {
            $token = Get-GitHubToken
            if ($token) {
                $options += '--header=Accept: application/octet-stream'
                $options += "--header=Authorization: Bearer $token"
                $options += '--header=X-GitHub-Api-Version: 2022-11-28'
            }
        }

        if (Get-Command get_config -ErrorAction SilentlyContinue) {
            get_config PRIVATE_HOSTS | Where-Object { $_ -ne $null -and $url -match $_.match } | ForEach-Object {
                (ConvertFrom-StringData -StringData $_.Headers).GetEnumerator() | ForEach-Object {
                    $options += "--header=$($_.Key): $($_.Value)"
                }
            }

            $proxy = get_config PROXY
            if ($proxy -ne 'none') {
                if ([Net.Webrequest]::DefaultWebProxy.Address) {
                    $options += "--all-proxy=$([Net.Webrequest]::DefaultWebProxy.Address.Authority)"
                }
                if ([Net.Webrequest]::DefaultWebProxy.Credentials.UserName) {
                    $options += "--all-proxy-user=$([Net.Webrequest]::DefaultWebProxy.Credentials.UserName)"
                }
                if ([Net.Webrequest]::DefaultWebProxy.Credentials.Password) {
                    $options += "--all-proxy-passwd=$([Net.Webrequest]::DefaultWebProxy.Credentials.Password)"
                }
            }

            $moreOptions = get_config 'aria2-options'
            if ($moreOptions) {
                $options += $moreOptions
            }
        }

        Write-Host 'Starting download with aria2...' -ForegroundColor Cyan
        $oriConsoleEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding

        try {
            & $aria2c @options | ForEach-Object {
                if ([String]::IsNullOrWhiteSpace($_)) { return }
                $len = $Host.UI.RawUI.WindowSize.Width - $_.Length - 20
                $blank = if ($len -gt 0) { ' ' * $len } else { '' }
                $color = 'Gray'
                $noNewLine = $false

                if ($_.StartsWith('(OK):')) {
                    $noNewLine = $true
                    $color = 'Green'
                } elseif ($_.StartsWith('[') -and $_.EndsWith(']')) {
                    $noNewLine = $true
                    $color = 'Cyan'
                } elseif ($_.StartsWith('Download Results:')) {
                    $noNewLine = $false
                }

                Write-Host "`rDownload: $_$blank" -ForegroundColor $color -NoNewline:$noNewLine
            }
            Write-Host ''
        } finally {
            [Console]::OutputEncoding = $oriConsoleEncoding
        }

        if ($LASTEXITCODE -eq 0 -and (Test-Path $to)) {
            if (Test-Path "$to.aria2") {
                Remove-Item "$to.aria2" -Force -ErrorAction SilentlyContinue
            }
            return
        }

        $fallback = if (Get-Command get_config -ErrorAction SilentlyContinue) { get_config ARIA2-FALLBACK-ENABLED $true } else { $true }
        if (-not $fallback) {
            throw "Download via aria2 failed! (Exit code: $LASTEXITCODE)"
        }
        Write-Host "Download via aria2 failed (Exit code: $LASTEXITCODE), falling back to default downloader..." -ForegroundColor Yellow
    }

    $origStartDownload = Get-Command Start-Download -CommandType Function -ErrorAction SilentlyContinue
    if ($origStartDownload) {
        & $origStartDownload $url $to $cookies
    } else {
        $progress = [console]::isoutputredirected -eq $false -and $host.name -ne 'Windows PowerShell ISE Host'
        $resolvedUrl = if (Get-Command handle_special_urls -ErrorAction SilentlyContinue) { handle_special_urls $url } else { $url }
        Invoke-Download $resolvedUrl $to $cookies $progress
    }
}

Set-Alias -Name Start-Download -Value global:Invoke-Aria2StartDownload -Scope Global -Force
