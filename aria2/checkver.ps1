<#
.SYNOPSIS
    Check manifest for a newer version (with aria2 download support).
#>
param(
    [String] $App = '*',
    [ValidateScript( {
        if (!(Test-Path $_ -Type Container)) {
            throw "$_ is not a directory!"
        } else {
            $true
        }
    })]
    [String] $Dir,
    [Switch] $Update,
    [Switch] $ForceUpdate,
    [Switch] $SkipUpdated,
    [String] $Version = '',
    [Switch] $ThrowError
)

if (!$env:SCOOP_HOME) { $env:SCOOP_HOME = Convert-Path (scoop prefix scoop) }

. "$env:SCOOP_HOME\lib\core.ps1"
. "$env:SCOOP_HOME\lib\autoupdate.ps1"
. "$env:SCOOP_HOME\lib\manifest.ps1"
. "$env:SCOOP_HOME\lib\buckets.ps1"
. "$env:SCOOP_HOME\lib\json.ps1"
. "$env:SCOOP_HOME\lib\versions.ps1"
. "$env:SCOOP_HOME\lib\download.ps1"
. "$PSScriptRoot\download.ps1"

if ($App -ne '*' -and (Test-Path $App -PathType Leaf)) {
    $Dir = Split-Path $App
    $files = Get-ChildItem $Dir -Filter (Split-Path $App -Leaf)
} elseif ($Dir) {
    $Dir = Convert-Path $Dir
    $files = Get-ChildItem $Dir -Filter "$App.json" -Recurse
} else {
    $Dir = Convert-Path "$PSScriptRoot\..\bucket"
    $files = Get-ChildItem $Dir -Filter "$App.json" -Recurse
}

$GitHubToken = Get-GitHubToken

# don't use $Version with $App = '*'
if ($App -eq '*' -and $Version -ne '') {
    throw "Don't use '-Version' with '-App *'!"
}

# get apps to check
$Queue = @()
$json = ''
$files | ForEach-Object {
    $file = $_.FullName
    $json = parse_json $file
    if ($json.checkver) {
        $Queue += , @($_.BaseName, $json, $file)
    }
}

# clear any existing events
Get-Event | Remove-Event
Get-EventSubscriber | Unregister-Event

# start all downloads
$in_progress = 0
$Queue | ForEach-Object {
    $name, $json, $file = $_

    $substitutions = Get-VersionSubstitution $json.version # 'autoupdate.ps1'

    $wc = New-Object Net.Webclient
    if ($json.checkver.useragent) {
        $wc.Headers.Add('User-Agent', (substitute $json.checkver.useragent $substitutions))
    } else {
        $wc.Headers.Add('User-Agent', (Get-UserAgent))
    }

    # Not Specified
    $url = $json.homepage
    $regex = ''
    $jsonpath = ''
    $xpath = ''
    $replace = ''

    if ($json.checkver.url) {
        $url = $json.checkver.url
    }

    if ($json.checkver.re) {
        $regex = $json.checkver.re
    } elseif ($json.checkver.regex) {
        $regex = $json.checkver.regex
    }

    if (($json.checkver -eq 'github') -or $json.checkver.github) {
        $githubUrlPattern = '^https://((www\.)?github\.com/[\w.-]+/[\w.-]+/?|api\.github\.com/repos/[\w.-]+/[\w.-]+/.+)$'

        $inputGithubUrl = $json.homepage
        $fieldUsed = 'homepage'
        if ($json.checkver.github) {
            $inputGithubUrl = $json.checkver.github
            $fieldUsed = 'checkver.github'
        }

        if ($inputGithubUrl -notmatch $githubUrlPattern) {
            error "$name checkver expects $fieldUsed to be a valid GitHub repository URL"
            return
        }

        $url = $inputGithubUrl.TrimEnd('/')
        if ($url -notlike 'https://api.github.com*') {
            $url = $url + '/releases/latest'
        }

        if ($GitHubToken) {
            $url = $url -replace '//(www\.)?github\.com/', '//api.github.com/repos/'
            $wc.Headers.Add('Authorization', "token $GitHubToken")
        }

        if ($url -like 'https://api.github.com*') {
            # Default jsonpath/regex in GitHub API mode
            if (-not $json.checkver.script) {
                $jsonpath = '$.tag_name'
            }
            if (-not $regex) {
                $regex = '(?:v|V)?([\d.-]+)'
            }
        } elseif (-not $regex) {
            # Default regex in GitHub HTML mode
            $regex = '/releases/tag/(?:v|V)?([\d.-]+)'
        }
    }

    # SourceForge
    if ($regex) {
        $sourceforgeRegex = $regex
    } else {
        $sourceforgeRegex = '(?!\.)([\d.]+)(?<=\d)'
    }
    if ($json.checkver -eq 'sourceforge') {
        if ($json.homepage -match '//(sourceforge|sf)\.net/projects/(?<project>[^/]+)(/files/(?<path>[^/]+))?|//(?<project>[^.]+)\.(sourceforge\.(net|io)|sf\.net)') {
            $project = $Matches['project']
            $path = $Matches['path']
        } else {
            $project = strip_ext $name
        }
        $url = "https://sourceforge.net/projects/$project/rss"
        if ($path) {
            $url = $url + '?path=/' + $path.TrimStart('/')
        }
        $regex = "CDATA\[/$path/.*?$sourceforgeRegex.*?\]".Replace('//', '/')
    }
    if ($json.checkver.sourceforge) {
        if ($json.checkver.sourceforge -is [System.String] -and $json.checkver.sourceforge -match '(?<project>[\w-]*)(/(?<path>.*))?') {
            $project = $Matches['project']
            $path = $Matches['path']
        } else {
            $project = $json.checkver.sourceforge.project
            $path = $json.checkver.sourceforge.path
        }
        $url = "https://sourceforge.net/projects/$project/rss"
        if ($path) {
            $url = $url + '?path=/' + $path.TrimStart('/')
        }
        $regex = "CDATA\[/$path/.*?$sourceforgeRegex.*?\]".Replace('//', '/')
    }

    if ($json.checkver.jp) {
        $jsonpath = $json.checkver.jp
    }
    if ($json.checkver.jsonpath) {
        $jsonpath = $json.checkver.jsonpath
    }
    if ($json.checkver.xpath) {
        $xpath = $json.checkver.xpath
    }

    if ($json.checkver.replace -is [System.String]) {
        $replace = $json.checkver.replace
    }

    if (!$jsonpath -and !$regex -and !$xpath) {
        $regex = $json.checkver
    }

    $reverse = $json.checkver.reverse -and $json.checkver.reverse -eq 'true'

    $url = substitute $url $substitutions

    $state = New-Object psobject @{
        app      = $name
        file     = $file
        url      = $url
        regex    = $regex
        json     = $json
        jsonpath = $jsonpath
        xpath    = $xpath
        reverse  = $reverse
        replace  = $replace
    }

    get_config PRIVATE_HOSTS | Where-Object { $_ -ne $null -and $url -match $_.match } | ForEach-Object {
        (ConvertFrom-StringData -StringData $_.Headers).GetEnumerator() | ForEach-Object {
            $wc.Headers[$_.Key] = $_.Value
        }
    }

    if ($json.checkver.referer) {
        $wc.Headers.Add('Referer', (substitute $json.checkver.referer $substitutions))
    } else {
        $wc.Headers.Add('Referer', (strip_filename $url))
    }
    Register-ObjectEvent $wc downloadDataCompleted -ErrorAction Stop | Out-Null
    $wc.DownloadDataAsync($url, $state)
    $in_progress++
}

function next($er) {
    Write-Host "$App`: " -NoNewline
    Write-Host $er -ForegroundColor DarkRed
}

# wait for all to complete
while ($in_progress -gt 0) {
    $ev = Wait-Event
    Remove-Event $ev.SourceIdentifier
    $in_progress--

    $state = $ev.SourceEventArgs.UserState
    $result = $ev.SourceEventArgs.Result
    $app = $state.app
    $file = $state.file
    $json = $state.json
    $url = $state.url
    $regexp = $state.regex
    $jsonpath = $state.jsonpath
    $xpath = $state.xpath
    $script = $json.checkver.script
    $reverse = $state.reverse
    $replace = $state.replace
    $expected_ver = $json.version
    $ver = $Version

    $matchesHashtable = @{}

    if (!$ver) {
        if (!$regexp -and $replace) {
            next "'replace' requires 're' or 'regex'"
            continue
        }
        $err = $ev.SourceEventArgs.Error
        if ($err) {
            if (!$script) {
                next "$($err.message)`r`nURL $url is not valid"
                continue
            } else {
                Write-Host "$($err.message)`r`nURL $url is not valid. Falling back to checkver.script ..."
            }
        }

        $page = $null
        $source = $url

        if ($url -and !$err) {
            $ms = New-Object System.IO.MemoryStream
            $ms.Write($result, 0, $result.Length)
            $ms.Seek(0, 0) | Out-Null
            if ($result[0] -eq 0x1F -and $result[1] -eq 0x8B) {
                $ms = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
            }
            $page = (New-Object System.IO.StreamReader($ms, (Get-Encoding $wc))).ReadToEnd()
        }

        if ($script) {
            $page = Invoke-Command ([scriptblock]::Create($script -join "`r`n"))
            $source = 'the output of script'
        }

        if ($null -eq $page) {
            next "couldn't retrieve content from $source"
            continue
        }

        if ($jsonpath) {
            $noregex = [String]::IsNullOrEmpty($regexp)
            $ver = json_path $page $jsonpath $null ($reverse -and $noregex) $noregex
            if (!$ver) {
                $ver = json_path_legacy $page $jsonpath
            }
            if (!$ver) {
                next "couldn't find '$jsonpath' in $source"
                continue
            }
        }

        if ($xpath) {
            $xml = [xml]$page
            $nsList = $xml.SelectNodes("//namespace::*[not(. = ../../namespace::*)]")
            $nsmgr = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
            $nsList | ForEach-Object {
                if ($_.LocalName -eq 'xmlns') {
                    $nsmgr.AddNamespace('ns', $_.Value)
                    $xpath = $xpath -replace '/([^:/]+)((?=/)|(?=$))', '/ns:$1'
                } else {
                    $nsmgr.AddNamespace($_.LocalName, $_.Value)
                }
            }
            $ver = $xml.SelectSingleNode($xpath, $nsmgr).'#text'
            if (!$ver) {
                next "couldn't find '$($xpath -replace 'ns:', '')' in $source"
                continue
            }
        }

        if ($jsonpath -and $regexp) {
            $page = $ver
            $ver = ''
        }

        if ($xpath -and $regexp) {
            $page = $ver
            $ver = ''
        }

        if ($regexp) {
            $re = New-Object System.Text.RegularExpressions.Regex($regexp)
            if ($reverse) {
                $match = $re.Matches($page) | Select-Object -Last 1
            } else {
                $match = $re.Matches($page) | Select-Object -First 1
            }

            if ($match -and $match.Success) {
                $re.GetGroupNames() | ForEach-Object { $matchesHashtable.Add($_, $match.Groups[$_].Value) }
                $ver = $matchesHashtable['1']
                if ($replace) {
                    $ver = $re.Replace($match.Value, $replace)
                }
                if (!$ver) {
                    $ver = $matchesHashtable['version']
                }
            } else {
                next "couldn't match '$regexp' in $source"
                continue
            }
        }

        if (!$ver) {
            next "couldn't find new version in $source"
            continue
        }
    }

    # Skip actual only if versions are same and there is no -f
    if (($ver -eq $expected_ver) -and !$ForceUpdate -and $SkipUpdated) { continue }

    Write-Host "$app`: " -NoNewline

    # version hasn't changed (step over if forced update)
    if ($ver -eq $expected_ver -and !$ForceUpdate) {
        Write-Host $ver -ForegroundColor DarkGreen
        continue
    }

    Write-Host $ver -ForegroundColor DarkRed -NoNewline
    Write-Host " (scoop version is $expected_ver)" -NoNewline
    $update_available = (Compare-Version -ReferenceVersion $ver -DifferenceVersion $expected_ver) -ne 0

    if ($json.autoupdate -and $update_available) {
        Write-Host ' autoupdate available' -ForegroundColor Cyan
    } else {
        Write-Host ''
    }

    # forcing an update implies updating, right?
    if ($ForceUpdate) { $Update = $true }

    if ($Update -and $json.autoupdate) {
        if ($ForceUpdate) {
            Write-Host 'Forcing autoupdate!' -ForegroundColor DarkMagenta
        }
        try {
            Invoke-AutoUpdate $app $file $json $ver $matchesHashtable # 'autoupdate.ps1'
        } catch {
            if ($ThrowError) {
                throw $_
            } else {
                error $_.Exception.Message
            }
        }
    }
}
