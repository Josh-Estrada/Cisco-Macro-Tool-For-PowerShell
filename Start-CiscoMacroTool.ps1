#Requires -Version 5.1
<#
.SYNOPSIS
    Interactive menu for the Cisco Macro Tool.

.DESCRIPTION
    Wraps the CiscoRoomKit module in a guided menu. Everything the menu does
    can also be scripted directly against the module, e.g.:

        Import-Module .\CiscoRoomKit.psm1
        Invoke-MacroDeployment -DeviceCsv .\devices.csv -MacroPath .\macros\ -CertificatePath .\ca.pem

    Requires only built-in PowerShell (5.1 or 7+) - no external modules.
#>

[CmdletBinding()]
param()

Set-Location -LiteralPath $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'CiscoRoomKit.psm1') -Force

function Read-TrimmedInput {
    param([Parameter(Mandatory)] [string]$Prompt, [string]$Default = '')
    $value = Read-Host $Prompt
    $value = "$value".Trim().Trim('"')
    if (-not $value) { return $Default }
    return $value
}

function Read-ExistingPath {
    <# Prompts until the user supplies an existing path (or blank to cancel). #>
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [string]$Default = ''
    )
    while ($true) {
        $suffix = ''
        if ($Default) { $suffix = " [default: $Default]" }
        $value = Read-TrimmedInput -Prompt ($Prompt + $suffix) -Default $Default
        if (-not $value) { return '' }
        if (Test-Path -LiteralPath $value) { return $value }
        Write-Host "  Path not found: $value (blank to cancel)" -ForegroundColor Red
    }
}

function Get-DeviceCsvInput {
    <# Prompts for the device CSV and, if any rows are missing credentials,
       collects a shared credential once. Returns $null if cancelled. #>
    $defaultCsv = ''
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'devices.csv')) {
        $defaultCsv = Join-Path $PSScriptRoot 'devices.csv'
    }
    $csvPath = Read-ExistingPath -Prompt 'Path to device CSV (columns: name,host,username,password)' -Default $defaultCsv
    if (-not $csvPath) { return $null }

    $credential = $null
    try {
        # First pass without credentials; if rows are missing them, ask once.
        [void](Import-DeviceList -Path $csvPath)
    } catch {
        if ($_.Exception.Message -like '*no username/password*') {
            Write-Host '  Some rows have no username/password - enter shared admin credentials for those devices.' -ForegroundColor Yellow
            $credential = Get-Credential -Message 'Shared device admin credentials'
            if (-not $credential) { return $null }
        } else {
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
            return $null
        }
    }

    return [pscustomobject]@{ Path = $csvPath; Credential = $credential }
}

function Read-MacroSourceInput {
    Write-Host ''
    Write-Host 'Macro source can be:' -ForegroundColor Cyan
    Write-Host '  - a single .js file            (one macro to every device)'
    Write-Host '  - a directory                  (every .js inside, to every device)'
    Write-Host '  - a .zip package               (extracted; every .js inside)'
    Write-Host '  - several of the above, comma-separated'
    $value = Read-TrimmedInput -Prompt 'Macro source path(s)'
    if (-not $value) { return @() }
    return @($value -split ',' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
}

function Read-CertificateSourceInput {
    param([string]$Prompt = 'CA certificate file/directory path(s) (blank for none)')
    $value = Read-TrimmedInput -Prompt $Prompt
    if (-not $value) { return @() }
    return @($value -split ',' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
}

function Read-ThrottleInput {
    $value = Read-TrimmedInput -Prompt 'Parallel connections (1-100)' -Default '20'
    $parsed = 0
    if ([int]::TryParse($value, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 100) { return $parsed }
    Write-Host '  Invalid value, using 20.' -ForegroundColor Yellow
    return 20
}

function Invoke-MenuDeployMacros {
    Write-Host ''
    Write-Host '--- Deploy macros (optionally with CA certificates) ---' -ForegroundColor Cyan
    $csv = Get-DeviceCsvInput
    if (-not $csv) { return }

    $macroPaths = Read-MacroSourceInput
    if ($macroPaths.Count -eq 0) { Write-Host 'Cancelled.'; return }

    $certPaths = Read-CertificateSourceInput
    $throttle = Read-ThrottleInput

    $params = @{
        DeviceCsv     = $csv.Path
        MacroPath     = $macroPaths
        ThrottleLimit = $throttle
    }
    if ($certPaths.Count -gt 0) { $params.CertificatePath = $certPaths }
    if ($csv.Credential) { $params.Credential = $csv.Credential }

    try { [void](Invoke-MacroDeployment @params) }
    catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
}

function Invoke-MenuDeployPexipOtj {
    Write-Host ''
    Write-Host '--- Deploy Pexip OTJ packages (per-device ZIPs matched by name) ---' -ForegroundColor Cyan
    Write-Host 'Each device is matched to a ZIP whose filename contains the device'
    Write-Host 'name (spaces removed, case-insensitive). Unmatched devices are skipped.'
    $csv = Get-DeviceCsvInput
    if (-not $csv) { return }

    $zipDir = Read-ExistingPath -Prompt 'Directory containing the per-device ZIP packages'
    if (-not $zipDir) { Write-Host 'Cancelled.'; return }

    $certPaths = Read-CertificateSourceInput -Prompt 'Pexip CA certificate path(s) (blank for none)'
    $throttle = Read-ThrottleInput

    $params = @{
        DeviceCsv             = $csv.Path
        PerDeviceZipDirectory = $zipDir
        ThrottleLimit         = $throttle
    }
    if ($certPaths.Count -gt 0) { $params.CertificatePath = $certPaths }
    if ($csv.Credential) { $params.Credential = $csv.Credential }

    try { [void](Invoke-MacroDeployment @params) }
    catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
}

function Invoke-MenuDeployCertificates {
    Write-Host ''
    Write-Host '--- Upload CA certificates only ---' -ForegroundColor Cyan
    $csv = Get-DeviceCsvInput
    if (-not $csv) { return }

    $certPaths = Read-CertificateSourceInput -Prompt 'CA certificate file/directory path(s)'
    if ($certPaths.Count -eq 0) { Write-Host 'Cancelled.'; return }
    $throttle = Read-ThrottleInput

    $params = @{
        DeviceCsv       = $csv.Path
        CertificatePath = $certPaths
        ThrottleLimit   = $throttle
    }
    if ($csv.Credential) { $params.Credential = $csv.Credential }

    try { [void](Invoke-CertificateDeployment @params) }
    catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
}

function Invoke-MenuRemove {
    Write-Host ''
    Write-Host '--- Remove macros / UI panels ---' -ForegroundColor Cyan
    $csv = Get-DeviceCsvInput
    if (-not $csv) { return }

    Write-Host ''
    Write-Host 'Macros to remove:'
    Write-Host '  - comma-separated macro names (e.g. pexip-otj,pexip-scheduler)'
    Write-Host '  - "all" to remove every macro'
    Write-Host '  - blank to leave macros alone'
    $macroInput = Read-TrimmedInput -Prompt 'Macros'
    $allMacros = $macroInput -eq 'all'
    $macroNames = @()
    if ($macroInput -and -not $allMacros) {
        $macroNames = @($macroInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    Write-Host ''
    Write-Host 'Panels to remove (macros often ship a companion panel):'
    Write-Host '  - comma-separated panel IDs (run option 5 first to discover IDs)'
    Write-Host '  - "all" to remove every UI extension'
    Write-Host '  - blank to leave panels alone'
    $panelInput = Read-TrimmedInput -Prompt 'Panels'
    $allPanels = $panelInput -eq 'all'
    $panelIds = @()
    if ($panelInput -and -not $allPanels) {
        $panelIds = @($panelInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    if (-not $allMacros -and $macroNames.Count -eq 0 -and -not $allPanels -and $panelIds.Count -eq 0) {
        Write-Host 'Nothing selected - cancelled.'
        return
    }

    $throttle = Read-ThrottleInput

    $params = @{
        DeviceCsv     = $csv.Path
        MacroName     = $macroNames
        AllMacros     = $allMacros
        PanelId       = $panelIds
        AllPanels     = $allPanels
        ThrottleLimit = $throttle
    }
    if ($csv.Credential) { $params.Credential = $csv.Credential }

    try { [void](Invoke-MacroRemoval @params) }
    catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
}

function Invoke-MenuInventory {
    Write-Host ''
    Write-Host '--- Fleet inventory (macros, panels, macro mode, software) ---' -ForegroundColor Cyan
    $csv = Get-DeviceCsvInput
    if (-not $csv) { return }
    $throttle = Read-ThrottleInput

    $params = @{ DeviceCsv = $csv.Path; ThrottleLimit = $throttle }
    if ($csv.Credential) { $params.Credential = $csv.Credential }

    try { [void](Get-FleetInventory @params) }
    catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
}

function Invoke-MenuConnectivity {
    Write-Host ''
    Write-Host '--- Test connectivity (no changes are made) ---' -ForegroundColor Cyan
    $csv = Get-DeviceCsvInput
    if (-not $csv) { return }
    $throttle = Read-ThrottleInput

    $params = @{ DeviceCsv = $csv.Path; ThrottleLimit = $throttle }
    if ($csv.Credential) { $params.Credential = $csv.Credential }

    try { [void](Test-FleetConnectivity @params) }
    catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
}

# ----------------------------------------------------------------------------
#  Main menu loop
# ----------------------------------------------------------------------------

while ($true) {
    Write-Host ''
    Write-Host '==========================================' -ForegroundColor Cyan
    Write-Host '  Cisco Macro Tool for PowerShell' -ForegroundColor Cyan
    Write-Host '==========================================' -ForegroundColor Cyan
    Write-Host '  1. Deploy macros (file / folder / ZIP, + optional CA certs)'
    Write-Host '  2. Deploy Pexip OTJ packages (per-device ZIPs)'
    Write-Host '  3. Upload CA certificates only'
    Write-Host '  4. Remove macros and/or UI panels'
    Write-Host '  5. Fleet inventory report (macros, panels, software)'
    Write-Host '  6. Test connectivity (dry run)'
    Write-Host '  7. Exit'
    Write-Host ''
    Write-Host '  Tip: every run writes a log, a results CSV, and a failed-'
    Write-Host '  devices CSV under .\logs\. Feed the failed CSV back in as'
    Write-Host '  the device list to retry only the failures.'
    Write-Host ''
    $choice = Read-Host 'Choose an option (1-7)'

    switch ($choice) {
        '1' { Invoke-MenuDeployMacros }
        '2' { Invoke-MenuDeployPexipOtj }
        '3' { Invoke-MenuDeployCertificates }
        '4' { Invoke-MenuRemove }
        '5' { Invoke-MenuInventory }
        '6' { Invoke-MenuConnectivity }
        '7' { Write-Host 'Goodbye.'; return }
        default { Write-Host 'Invalid option.' -ForegroundColor Red }
    }
}
