#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Cluster', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    # Optional manual ESXi host list: one hostname or IP address per line. Use -HostFile to bypass vCenter cluster discovery.
    [Parameter(ParameterSetName = 'HostFile')]
    [string]$HostFile,

    [Parameter(ParameterSetName = 'Cluster')]
    [string]$ClusterName,

    [Parameter(ParameterSetName = 'Cluster')]
    [string]$vCenterServer,

    [Parameter(ParameterSetName = 'Cluster')]
    [string]$ClusterInputFile = (Join-Path $PSScriptRoot 'clusternames.txt'),

    [string]$OutputRoot = (Join-Path $PSScriptRoot 'Results'),

    [pscredential]$SshCredential,

    [pscredential]$VIServerCredential,

    [switch]$RestartNtp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ModuleAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$InstallHint
    )

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "Required module '$Name' was not found. $InstallHint"
    }

    Import-Module $Name -ErrorAction Stop | Out-Null
}

function Get-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Name)

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $safeName = $Name
    foreach ($char in $invalidChars) {
        $safeName = $safeName.Replace($char, '_')
    }

    return $safeName
}

function Get-SingleLineText {
    param(
        [AllowNull()]
        [string]$Text,
        [int]$MaxLength = 180
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return '<empty>'
    }

    $singleLine = ($Text -replace '\s+', ' ').Trim()
    if ($singleLine.Length -gt $MaxLength) {
        return $singleLine.Substring(0, $MaxLength - 3) + '...'
    }

    return $singleLine
}

function Get-TextHash {
    param([AllowNull()][string]$Text)

    $normalized = if ($null -eq $Text) { '' } else { ($Text -replace "`r`n", "`n").Trim() }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
        $hashBytes = $sha256.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function ConvertFrom-KeyValueText {
    param([AllowNull()][string]$Text)

    $result = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $result
    }

    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*([^:]+?)\s*:\s*(.+?)\s*$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            if (-not $result.Contains($key)) {
                $result[$key] = $value
            }
        }
    }

    return $result
}

function Get-KeyValueField {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Map,

        [Parameter(Mandatory = $true)]
        [string[]]$Candidates
    )

    foreach ($candidate in $Candidates) {
        foreach ($key in $Map.Keys) {
            if ($key -ieq $candidate) {
                return $Map[$key]
            }
        }
    }

    foreach ($candidate in $Candidates) {
        foreach ($key in $Map.Keys) {
            if ($key -ilike "*$candidate*") {
                return $Map[$key]
            }
        }
    }

    return $null
}

function Get-ClusterInputsFromFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cluster input file not found: $Path"
    }

    $parsed = @{
        ClusterName   = $null
        vCenterServer = $null
    }

    $lines = Get-Content -LiteralPath $Path |
        Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } |
        ForEach-Object { $_.Trim() }

    foreach ($line in $lines) {
        if ($line -match '^\s*([^:=]+?)\s*[:=]\s*(.+?)\s*$') {
            $key = $Matches[1].Trim().ToLowerInvariant()
            $value = $Matches[2].Trim()
            switch -Regex ($key) {
                '^(cluster|clustername)$' {
                    if (-not [string]::IsNullOrWhiteSpace($value)) {
                        $parsed.ClusterName = $value
                    }
                }
                '^(vcenter|vcenterserver|server|vcenterip|vcenteraddress|ip)$' {
                    if (-not [string]::IsNullOrWhiteSpace($value)) {
                        $parsed.vCenterServer = $value
                    }
                }
            }
        }
    }

    if (-not $parsed.ClusterName -and $lines.Count -ge 1) {
        $parsed.ClusterName = $lines[0]
    }

    if (-not $parsed.vCenterServer -and $lines.Count -ge 2) {
        $parsed.vCenterServer = $lines[1]
    }

    return [pscustomobject]$parsed
}

function Get-HostNamesFromCluster {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$vCenterServer,

        [pscredential]$Credential
    )

    Assert-ModuleAvailable -Name 'VMware.PowerCLI' -InstallHint 'Install VMware PowerCLI if you want to query hosts from a vSphere cluster.'

    $connection = $null
    if ($vCenterServer) {
        if ($Credential) {
            $connection = Connect-VIServer -Server $vCenterServer -Credential $Credential -ErrorAction Stop
        }
        else {
            $connection = Connect-VIServer -Server $vCenterServer -ErrorAction Stop
        }
    }

    try {
        $cluster = Get-Cluster -Name $Name -ErrorAction Stop
        return $cluster | Get-VMHost | Sort-Object Name | Select-Object -ExpandProperty Name
    }
    finally {
        if ($connection) {
            Disconnect-VIServer -Server $connection -Confirm:$false | Out-Null
        }
    }
}

function Invoke-EsxiCommand {
    param(
        [Parameter(Mandatory = $true)]
        [int]$SessionId,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    try {
        $result = Invoke-SSHCommand -SessionId $SessionId -Command $Command -ErrorAction Stop
        $stdout = @($result.Output) -join [Environment]::NewLine
        $stderr = @($result.Error) -join [Environment]::NewLine
        $output = $stdout
        if ([string]::IsNullOrWhiteSpace($output) -and -not [string]::IsNullOrWhiteSpace($stderr)) {
            $output = $stderr
        }

        [pscustomobject]@{
            Label      = $Label
            Command    = $Command
            Output     = $output.TrimEnd()
            ExitStatus = $result.ExitStatus
            Success    = ($result.ExitStatus -eq 0)
        }
    }
    catch {
        [pscustomobject]@{
            Label      = $Label
            Command    = $Command
            Output     = $_.Exception.Message
            ExitStatus = -1
            Success    = $false
        }
    }
}

function Get-TargetHostNames {
    if ($PSCmdlet.ParameterSetName -eq 'HostFile') {
        if (-not (Test-Path -LiteralPath $HostFile)) {
            throw "Host file not found: $HostFile"
        }

        return Get-Content -LiteralPath $HostFile |
            Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } |
            ForEach-Object { $_.Trim() } |
            Select-Object -Unique
    }

    $resolvedClusterName = $ClusterName
    $resolvedVCenterServer = $vCenterServer

    if ($ClusterInputFile) {
        $clusterInput = Get-ClusterInputsFromFile -Path $ClusterInputFile
        if (-not $resolvedClusterName) {
            $resolvedClusterName = $clusterInput.ClusterName
        }

        if (-not $resolvedVCenterServer) {
            $resolvedVCenterServer = $clusterInput.vCenterServer
        }
    }

    if (-not $resolvedClusterName) {
        throw 'Cluster mode requires ClusterName directly or via ClusterInputFile.'
    }

    return Get-HostNamesFromCluster -Name $resolvedClusterName -vCenterServer $resolvedVCenterServer -Credential $VIServerCredential
}

function Write-HostReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [hashtable]$CommandResults
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("ESXi Time Sync Report")
    $lines.Add("Host: $HostName")
    $lines.Add("Collected: $(Get-Date -Format o)")
    $lines.Add('')

    foreach ($result in $CommandResults.Values) {
        $lines.Add('==============================')
        $lines.Add($result.Label)
        $lines.Add('==============================')
        $lines.Add("Command: $($result.Command)")
        $lines.Add("ExitStatus: $($result.ExitStatus)")
        $lines.Add('--- Output ---')
        if ([string]::IsNullOrWhiteSpace($result.Output)) {
            $lines.Add('<empty>')
        }
        else {
            $lines.Add($result.Output)
        }
        $lines.Add('')
    }

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

if (-not (Get-Command New-SSHSession -ErrorAction SilentlyContinue)) {
    Assert-ModuleAvailable -Name 'Posh-SSH' -InstallHint 'Install-Module Posh-SSH to connect to ESXi hosts over SSH.'
}
else {
    Import-Module Posh-SSH -ErrorAction Stop | Out-Null
}

if (-not $SshCredential) {
    $SshCredential = Get-Credential -Message 'Enter ESXi SSH credentials (usually root)'
}

$targetHosts = @(Get-TargetHostNames)
if (-not $targetHosts -or $targetHosts.Count -eq 0) {
    throw 'No ESXi hosts were resolved from the selected input source.'
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runRoot = Join-Path $OutputRoot $timestamp
$rawRoot = Join-Path $runRoot 'Raw'
New-Item -ItemType Directory -Path $rawRoot -Force | Out-Null

$commandMap = [ordered]@{
    'Host Date'            = 'date'
    'Host Information'     = 'esxcli system hostname get'
    'IPv4 Addressing'      = 'esxcli network ip interface ipv4 get'
    'NTP Config File'      = 'cat /etc/ntp.conf'
    'NTP Service Settings'  = 'esxcli system ntp get'
    'NTP Peers'            = 'ntpq -p'
    'NTP Peers Numeric'    = 'ntpq -pn'
    'Firewall NTP Rules'   = 'esxcli network firewall ruleset list | grep -i ntp'
    'BIOS / Platform'      = 'esxcli hardware platform get'
    'Hardware Clock'       = 'esxcli hardware clock get'
    'Chrony Config File'   = 'cat /etc/chrony.conf'
    'Chrony Tracking'      = 'chronyc tracking'
    'Chrony Sources'       = 'chronyc sources'
}

$allResults = New-Object System.Collections.Generic.List[object]
$connectionResults = New-Object System.Collections.Generic.List[object]

foreach ($targetHost in $targetHosts) {
    Write-Host "Querying $targetHost ..." -ForegroundColor Cyan

    $session = $null
    try {
        $session = New-SSHSession -ComputerName $targetHost -Credential $SshCredential -AcceptKey -ErrorAction Stop
        $sessionId = $session.SessionId

        $commandResults = [ordered]@{}
        foreach ($entry in $commandMap.GetEnumerator()) {
            $commandResults[$entry.Key] = Invoke-EsxiCommand -SessionId $sessionId -Command $entry.Value -Label $entry.Key
        }

        $hostFolder = Join-Path $rawRoot (Get-SafeFileName $targetHost)
        New-Item -ItemType Directory -Path $hostFolder -Force | Out-Null
        $reportPath = Join-Path $hostFolder 'esxi-time-sync-report.txt'
        Write-HostReport -Path $reportPath -HostName $targetHost -CommandResults $commandResults

        $ntpSettings = ConvertFrom-KeyValueText -Text $commandResults['NTP Service Settings'].Output
        $platformSettings = ConvertFrom-KeyValueText -Text $commandResults['BIOS / Platform'].Output
        $clockSettings = ConvertFrom-KeyValueText -Text $commandResults['Hardware Clock'].Output
        $hostInfoSettings = ConvertFrom-KeyValueText -Text $commandResults['Host Information'].Output
        $chronyTracking = $commandResults['Chrony Tracking'].Output
        $chronySources = $commandResults['Chrony Sources'].Output
        $chronyConfig = $commandResults['Chrony Config File'].Output
        $ntpConfig = $commandResults['NTP Config File'].Output
        $ntpqPeers = $commandResults['NTP Peers'].Output
        $ntpqPeersNumeric = $commandResults['NTP Peers Numeric'].Output
        $firewallRules = $commandResults['Firewall NTP Rules'].Output

        $enabledValue = Get-KeyValueField -Map $ntpSettings -Candidates @('Enabled', 'NTP Client Enabled', 'NTP daemon enabled')
        $serversValue = Get-KeyValueField -Map $ntpSettings -Candidates @('NTP Servers', 'Servers', 'Server')
        $biosVersion = Get-KeyValueField -Map $platformSettings -Candidates @('BIOS Version')
        $hardwareClock = Get-KeyValueField -Map $clockSettings -Candidates @('Hardware Clock')
        $reportedHostName = Get-KeyValueField -Map $hostInfoSettings -Candidates @('Host Name', 'Fully Qualified Domain Name')
        if (-not $hardwareClock) {
            $hardwareClock = Get-SingleLineText -Text $commandResults['Hardware Clock'].Output
        }

        $hostSummary = [pscustomobject]@{
            HostName              = $targetHost
            Date                  = Get-SingleLineText -Text $commandResults['Host Date'].Output -MaxLength 80
            ReportedHostName      = if ($null -ne $reportedHostName) { $reportedHostName } else { '<not reported>' }
            IPv4Summary           = Get-SingleLineText -Text $commandResults['IPv4 Addressing'].Output -MaxLength 180
            NtpEnabled            = if ($null -ne $enabledValue) { $enabledValue } else { '<not reported>' }
            NtpServers            = if ($null -ne $serversValue) { $serversValue } else { '<not reported>' }
            NtpConfigHash         = Get-TextHash -Text $ntpConfig
            NtpPeersHash          = Get-TextHash -Text $ntpqPeers
            NtpPeersNumericHash   = Get-TextHash -Text $ntpqPeersNumeric
            FirewallNtpHash       = Get-TextHash -Text $firewallRules
            BIOSVersion           = if ($null -ne $biosVersion) { $biosVersion } else { '<not reported>' }
            HardwareClock         = if ($null -ne $hardwareClock) { $hardwareClock } else { '<not reported>' }
            ChronyDetected        = if ($chronyConfig -match '(?i)chrony|chronyc' -or $chronyTracking -notmatch 'not found|not available|failed' -or $chronySources -notmatch 'not found|not available|failed') { 'Yes' } else { 'No' }
            ChronyConfigHash      = Get-TextHash -Text $chronyConfig
            ChronyTrackingHash    = Get-TextHash -Text $chronyTracking
            ChronySourcesHash     = Get-TextHash -Text $chronySources
            ReportPath            = $reportPath
        }

        $allResults.Add($hostSummary)
        $connectionResults.Add([pscustomobject]@{
            HostName = $targetHost
            Status   = 'Success'
            SessionId = $sessionId
        })

        if ($RestartNtp -and $PSCmdlet.ShouldProcess($targetHost, 'Toggle ESXi NTP service off then on')) {
            $restartCommands = [ordered]@{
                'Restart NTP - Disable' = 'esxcli system ntp set -e 0'
                'Restart NTP - Enable'  = 'esxcli system ntp set -e 1'
                'Restart NTP - Verify'  = 'esxcli system ntp get'
            }

            $restartResults = [ordered]@{}
            foreach ($entry in $restartCommands.GetEnumerator()) {
                $restartResults[$entry.Key] = Invoke-EsxiCommand -SessionId $sessionId -Command $entry.Value -Label $entry.Key
            }

            $restartPath = Join-Path $hostFolder 'restart-ntp.txt'
            Write-HostReport -Path $restartPath -HostName $targetHost -CommandResults $restartResults
        }
    }
    catch {
        $connectionResults.Add([pscustomobject]@{
            HostName = $targetHost
            Status   = "Failed: $($_.Exception.Message)"
            SessionId = $null
        })
        Write-Warning "Failed to query $targetHost : $($_.Exception.Message)"
    }
    finally {
        if ($session) {
            Remove-SSHSession -SessionId $session.SessionId | Out-Null
        }
    }
}

$csvPath = Join-Path $runRoot 'esxi_time_sync_comparison.csv'
$allResults | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host '============================== ESXi TIME SYNC COMPARISON ==============================' -ForegroundColor Yellow
$allResults |
    Select-Object HostName, Date, NtpEnabled, NtpServers, ChronyDetected, BIOSVersion, HardwareClock |
    Format-Table -AutoSize -Wrap

$compareFields = @(
    'NtpEnabled',
    'NtpServers',
    'NtpConfigHash',
    'NtpPeersHash',
    'NtpPeersNumericHash',
    'FirewallNtpHash',
    'BIOSVersion',
    'HardwareClock',
    'ChronyDetected',
    'ChronyConfigHash',
    'ChronyTrackingHash',
    'ChronySourcesHash'
)

$diffRows = foreach ($field in $compareFields) {
    $values = $allResults | ForEach-Object { $_.$field } | Select-Object -Unique
    if ((@($values)).Count -gt 1) {
        [pscustomobject]@{
            Field  = $field
            Values = ($values -join ' | ')
        }
    }
}

Write-Host ''
Write-Host '============================== DIFFERENCES ==========================================' -ForegroundColor Red
if ($diffRows) {
    $diffRows | Format-Table -AutoSize -Wrap
}
else {
    Write-Host 'No differences were detected in the summarized fields.' -ForegroundColor Green
}

Write-Host ''
Write-Host "Per-host reports saved under: $rawRoot" -ForegroundColor Cyan
Write-Host "Comparison CSV saved to: $csvPath" -ForegroundColor Cyan

if ($connectionResults | Where-Object { $_.Status -notlike 'Success' }) {
    Write-Warning 'One or more hosts could not be queried. Review the per-host report and warning messages.'
}
