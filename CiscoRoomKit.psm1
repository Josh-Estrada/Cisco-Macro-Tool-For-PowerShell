#Requires -Version 5.1
<#
.SYNOPSIS
    CiscoRoomKit - Bulk macro, certificate, and UI panel management for Cisco
    RoomOS devices (Room Kit, Board, Desk series) over the HTTPS xAPI.

.DESCRIPTION
    Pure PowerShell implementation with no external dependencies. Works on
    Windows PowerShell 5.1 (preinstalled on Windows) and PowerShell 7+, so it
    can run in airgapped environments with nothing extra installed.

    Public entry points (all fleet-scale, parallel, with retry + logging):
        Invoke-MacroDeployment        - Upload/activate macros (+ optional CA certs) to many devices
        Invoke-CertificateDeployment  - Upload CA certificates only
        Invoke-MacroRemoval           - Remove macros (named or all) and optionally UI panels
        Invoke-PanelRemoval           - Remove UI extension panels only
        Get-FleetInventory            - Audit macros/panels/macro-mode across the fleet
        Test-FleetConnectivity        - Dry-run reachability/auth check of a device CSV

    Single-device building blocks are also exported (Save-RoomKitMacro,
    Add-RoomKitCACertificate, etc.) for scripting your own workflows.
#>

$script:ModuleFilePath = $PSCommandPath
$script:ModuleRoot     = Split-Path -Parent $PSCommandPath

# ============================================================================
#  Transport: TLS + self-signed certificate handling for PS 5.1 and PS 7+
# ============================================================================

function Initialize-XapiTransport {
    <# Prepares the process for HTTPS calls to devices with self-signed certs.
       PS 7+ uses -SkipCertificateCheck per request; PS 5.1 needs a
       process-wide validation callback and an explicit TLS 1.2 opt-in. #>
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSVersion.Major -ge 6) { return }

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = `
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    } catch { }

    if (-not ('CiscoRoomKit.CertPolicy' -as [type])) {
        # Parallel runspaces can race here; types are AppDomain-wide, so a
        # "type already exists" failure from the loser is harmless.
        try {
            Add-Type -TypeDefinition @'
using System.Net;
namespace CiscoRoomKit {
    public static class CertPolicy {
        public static void Enable() {
            ServicePointManager.ServerCertificateValidationCallback = delegate { return true; };
        }
    }
}
'@
        } catch {
            if (-not ('CiscoRoomKit.CertPolicy' -as [type])) { throw }
        }
    }
    [CiscoRoomKit.CertPolicy]::Enable()
}

# ============================================================================
#  Core xAPI client with retry / backoff
# ============================================================================

function Get-XapiFailureInfo {
    <# Classifies a transport error: which failures are worth retrying
       (timeouts, connection resets, 5xx, 429) vs. permanent (auth, 4xx). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ErrorRecord)

    $statusCode = $null
    try {
        $response = $ErrorRecord.Exception.Response
        if ($null -ne $response) { $statusCode = [int]$response.StatusCode }
    } catch { }

    $message = $ErrorRecord.Exception.Message

    if ($statusCode -eq 401 -or $statusCode -eq 403) {
        return [pscustomobject]@{ Retryable = $false; Kind = "Authentication failed (HTTP $statusCode) - check username/password and user role"; StatusCode = $statusCode }
    }
    if ($statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -le 599)) {
        return [pscustomobject]@{ Retryable = $true; Kind = "Server busy/error (HTTP $statusCode)"; StatusCode = $statusCode }
    }
    if ($null -ne $statusCode) {
        return [pscustomobject]@{ Retryable = $false; Kind = "HTTP $statusCode - $message"; StatusCode = $statusCode }
    }
    # No HTTP status: DNS failure, connection refused, TLS failure, timeout.
    return [pscustomobject]@{ Retryable = $true; Kind = "Network error - $message"; StatusCode = $null }
}

function Assert-XapiCommandSuccess {
    <# putxml returns HTTP 200 even when the command fails; the failure is an
       XML node carrying status="Error" and a <Reason>. Throw so callers can't
       mistake a rejected command for success. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [xml]$Response,
        [string]$Operation = 'xAPI command'
    )

    $errorNodes = $Response.SelectNodes('//*[@status="Error"]')
    if ($null -ne $errorNodes -and $errorNodes.Count -gt 0) {
        $reasons = New-Object System.Collections.Generic.List[string]
        foreach ($node in $errorNodes) {
            foreach ($reason in $node.SelectNodes('.//Reason')) {
                if ($reason.InnerText) { [void]$reasons.Add($reason.InnerText.Trim()) }
            }
            foreach ($detail in $node.SelectNodes('.//Details')) {
                if ($detail.InnerText) { [void]$reasons.Add($detail.InnerText.Trim()) }
            }
        }
        $reasonText = ($reasons | Select-Object -Unique) -join '; '
        if (-not $reasonText) { $reasonText = 'device returned status="Error" with no reason' }
        throw "$Operation rejected by device: $reasonText"
    }
}

function Invoke-XapiRequest {
    <# Sends one request to a device, with bounded retries and exponential
       backoff + jitter on transient failures. Returns the response as [xml]
       (or $null for empty bodies). Throws on final failure. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [string]$Body,
        [ValidateSet('GET', 'POST')] [string]$Method = 'POST',
        [string]$Path = '/putxml',
        [int]$TimeoutSec = 20,
        [int]$MaxAttempts = 3,
        [string]$Operation = 'xAPI request'
    )

    Initialize-XapiTransport

    $uri = "https://$($Device.Host)$Path"
    $authBytes = [System.Text.Encoding]::UTF8.GetBytes("$($Device.Username):$($Device.Password)")
    $headers = @{ Authorization = 'Basic ' + [System.Convert]::ToBase64String($authBytes) }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $params = @{
                Uri         = $uri
                Method      = $Method
                Headers     = $headers
                TimeoutSec  = $TimeoutSec
                ErrorAction = 'Stop'
            }
            if ($Method -eq 'POST') {
                $params.Body        = [System.Text.Encoding]::UTF8.GetBytes($Body)
                $params.ContentType = 'text/xml'
            }
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                $params.SkipCertificateCheck = $true
            }

            $raw = Invoke-RestMethod @params

            if ($null -eq $raw -or ($raw -is [string] -and [string]::IsNullOrWhiteSpace($raw))) { return $null }
            if ($raw -is [xml]) { $xml = $raw } else { $xml = [xml]"$raw" }
            Assert-XapiCommandSuccess -Response $xml -Operation $Operation
            return $xml
        } catch {
            # Command-level rejections from Assert-XapiCommandSuccess are never retryable.
            if ($_.Exception.Message -like '*rejected by device*') { throw }

            $failure = Get-XapiFailureInfo -ErrorRecord $_
            if (-not $failure.Retryable -or $attempt -ge $MaxAttempts) {
                throw "$Operation failed after $attempt attempt(s): $($failure.Kind)"
            }
            # Exponential backoff with jitter: 2s, 4s, 8s ... capped at 15s.
            $delayMs = [Math]::Min(15000, [Math]::Pow(2, $attempt) * 1000) + (Get-Random -Minimum 0 -Maximum 750)
            Start-Sleep -Milliseconds $delayMs
        }
    }
}

# ============================================================================
#  Device list handling (CSV import, validation, credentials)
# ============================================================================

function Import-DeviceList {
    <# Imports a device CSV. Accepts the current headers (name, host, username,
       password) and the legacy ones (system name, ip address). Rows missing a
       username/password fall back to -Credential (shared credential). Skips
       and warns on blank hosts and duplicate hosts. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [System.Management.Automation.PSCredential]$Credential
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "Device CSV not found: $Path" }
    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) { throw "Device CSV '$Path' contains no rows." }

    # Map flexible header names onto canonical fields.
    $columns = @{}
    foreach ($property in $rows[0].PSObject.Properties.Name) {
        switch -Regex ($property.Trim().ToLower()) {
            '^(name|system ?name|device ?name)$'            { $columns['Name'] = $property }
            '^(host|hostname|fqdn|ip|ip ?address|address)$' { $columns['Host'] = $property }
            '^(username|user ?name|user)$'                  { $columns['Username'] = $property }
            '^(password|pass)$'                             { $columns['Password'] = $property }
        }
    }
    if (-not $columns.ContainsKey('Host')) {
        throw "Device CSV '$Path' must contain a 'host' (or legacy 'ip address') column. Found columns: $($rows[0].PSObject.Properties.Name -join ', ')"
    }

    $sharedUser = $null
    $sharedPass = $null
    if ($Credential) {
        $networkCred = $Credential.GetNetworkCredential()
        $sharedUser = $networkCred.UserName
        $sharedPass = $networkCred.Password
    }

    $devices = New-Object System.Collections.Generic.List[object]
    $seenHosts = @{}
    $missingCredentialHosts = New-Object System.Collections.Generic.List[string]
    $rowNumber = 1

    foreach ($row in $rows) {
        $rowNumber++
        $hostValue = ''
        if ($columns.ContainsKey('Host')) { $hostValue = [string]$row.($columns['Host']) }
        $hostValue = $hostValue.Trim() -replace '^https?://', '' -replace '/+$', ''
        if (-not $hostValue) {
            Write-Warning "CSV row $rowNumber skipped: empty host."
            continue
        }
        $hostKey = $hostValue.ToLower()
        if ($seenHosts.ContainsKey($hostKey)) {
            Write-Warning "CSV row $rowNumber skipped: duplicate host '$hostValue' (first seen on row $($seenHosts[$hostKey]))."
            continue
        }
        $seenHosts[$hostKey] = $rowNumber

        $name = ''
        if ($columns.ContainsKey('Name')) { $name = ([string]$row.($columns['Name'])).Trim() }
        if (-not $name) { $name = $hostValue }

        $user = ''
        $pass = ''
        if ($columns.ContainsKey('Username')) { $user = ([string]$row.($columns['Username'])).Trim() }
        if ($columns.ContainsKey('Password')) { $pass = [string]$row.($columns['Password']) }

        $credentialSource = 'csv'
        if (-not $user -or -not $pass) {
            if ($null -ne $sharedUser) {
                $user = $sharedUser
                $pass = $sharedPass
                $credentialSource = 'shared'
            } else {
                [void]$missingCredentialHosts.Add($hostValue)
                continue
            }
        }

        [void]$devices.Add([pscustomobject]@{
            Name             = $name
            Host             = $hostValue
            Username         = $user
            Password         = $pass
            CredentialSource = $credentialSource
        })
    }

    if ($missingCredentialHosts.Count -gt 0) {
        throw "$($missingCredentialHosts.Count) device(s) in '$Path' have no username/password (first: $($missingCredentialHosts[0])). Supply shared credentials with -Credential, or fill in the CSV columns."
    }
    if ($devices.Count -eq 0) { throw "No usable devices found in '$Path'." }

    return ,$devices.ToArray()
}

# ============================================================================
#  Macro & certificate source resolution
# ============================================================================

function Resolve-MacroSource {
    <# Turns any mix of .js files, directories (all *.js inside), and .zip
       packages (extracted to a temp folder) into a list of
       @{ Name; Code; SourcePath } macro definitions. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$Path,
        # Receives temp directories the caller should delete when finished.
        [System.Collections.Generic.List[string]]$TempDirectories
    )

    $jsFiles = New-Object System.Collections.Generic.List[object]

    foreach ($item in $Path) {
        $item = $item.Trim().Trim('"')
        if (-not $item) { continue }
        if (-not (Test-Path -LiteralPath $item)) { throw "Macro source not found: $item" }

        $entry = Get-Item -LiteralPath $item
        if ($entry.PSIsContainer) {
            $found = @(Get-ChildItem -LiteralPath $entry.FullName -Filter *.js -File)
            if ($found.Count -eq 0) { throw "No .js files found in directory: $($entry.FullName)" }
            foreach ($file in $found) { [void]$jsFiles.Add($file) }
        } elseif ($entry.Extension -eq '.zip') {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("CiscoRoomKit_" + [System.IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            if ($null -ne $TempDirectories) { [void]$TempDirectories.Add($tempDir) }
            Expand-Archive -LiteralPath $entry.FullName -DestinationPath $tempDir -Force
            $found = @(Get-ChildItem -LiteralPath $tempDir -Filter *.js -File -Recurse)
            if ($found.Count -eq 0) { throw "ZIP package contains no .js files: $($entry.FullName)" }
            foreach ($file in $found) { [void]$jsFiles.Add($file) }
        } elseif ($entry.Extension -eq '.js') {
            [void]$jsFiles.Add($entry)
        } else {
            throw "Unsupported macro source '$item' - expected a .js file, a directory, or a .zip package."
        }
    }

    $macros = New-Object System.Collections.Generic.List[object]
    $seenNames = @{}
    foreach ($file in $jsFiles) {
        $macroName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($seenNames.ContainsKey($macroName)) {
            Write-Warning "Duplicate macro name '$macroName' - keeping the first occurrence ($($seenNames[$macroName])), skipping $($file.FullName)."
            continue
        }
        $seenNames[$macroName] = $file.FullName
        # ReadAllText handles BOM detection and defaults to UTF-8 (PS 5.1's
        # Get-Content default encoding would corrupt UTF-8 files without BOM).
        $code = [System.IO.File]::ReadAllText($file.FullName)
        if ([string]::IsNullOrWhiteSpace($code)) {
            Write-Warning "Macro file is empty, skipping: $($file.FullName)"
            continue
        }
        [void]$macros.Add([pscustomobject]@{
            Name       = $macroName
            Code       = $code
            SourcePath = $file.FullName
        })
    }

    if ($macros.Count -eq 0) { throw 'No usable macro files were found.' }
    return ,$macros.ToArray()
}

function ConvertTo-PemCertificateList {
    <# Extracts every certificate from a file. Handles PEM files (including
       bundles with several certificates) and binary DER (.cer/.der) files.
       Returns @{ Label; Pem; Subject; Thumbprint } entries. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$FilePath)

    $certs = New-Object System.Collections.Generic.List[object]
    $rawBytes = [System.IO.File]::ReadAllBytes($FilePath)
    $rawText = [System.Text.Encoding]::ASCII.GetString($rawBytes)

    $pemPattern = '-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----'
    $pemMatches = [regex]::Matches($rawText, $pemPattern)

    if ($pemMatches.Count -gt 0) {
        $index = 0
        foreach ($match in $pemMatches) {
            $index++
            $pem = ($match.Value -replace "`r`n", "`n").Trim()
            $subject = ''
            $thumbprint = ''
            try {
                $base64 = ($pem -replace '-----(BEGIN|END) CERTIFICATE-----', '') -replace '\s', ''
                $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,[System.Convert]::FromBase64String($base64))
                $subject = $x509.Subject
                $thumbprint = $x509.Thumbprint
            } catch { }
            [void]$certs.Add([pscustomobject]@{
                Label      = "$([System.IO.Path]::GetFileName($FilePath))#$index"
                Pem        = $pem
                Subject    = $subject
                Thumbprint = $thumbprint
            })
        }
    } else {
        # Binary DER - convert to PEM.
        try {
            $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,$rawBytes)
        } catch {
            throw "File is neither PEM nor a readable DER certificate: $FilePath ($($_.Exception.Message))"
        }
        $base64 = [System.Convert]::ToBase64String($x509.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
        $builder = New-Object System.Text.StringBuilder
        [void]$builder.AppendLine('-----BEGIN CERTIFICATE-----')
        for ($i = 0; $i -lt $base64.Length; $i += 64) {
            [void]$builder.AppendLine($base64.Substring($i, [Math]::Min(64, $base64.Length - $i)))
        }
        [void]$builder.Append('-----END CERTIFICATE-----')
        [void]$certs.Add([pscustomobject]@{
            Label      = [System.IO.Path]::GetFileName($FilePath)
            Pem        = $builder.ToString()
            Subject    = $x509.Subject
            Thumbprint = $x509.Thumbprint
        })
    }

    return ,$certs.ToArray()
}

function Resolve-CertificateSource {
    <# Accepts certificate files (.pem/.crt/.cer/.der) and/or directories of
       them; returns the flattened certificate list. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]]$Path)

    $allCerts = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Path) {
        $item = $item.Trim().Trim('"')
        if (-not $item) { continue }
        if (-not (Test-Path -LiteralPath $item)) { throw "Certificate source not found: $item" }

        $entry = Get-Item -LiteralPath $item
        $files = @()
        if ($entry.PSIsContainer) {
            $files = @(Get-ChildItem -LiteralPath $entry.FullName -File | Where-Object { $_.Extension -in '.pem', '.crt', '.cer', '.der' })
            if ($files.Count -eq 0) { throw "No certificate files (.pem/.crt/.cer/.der) found in directory: $($entry.FullName)" }
        } else {
            $files = @($entry)
        }
        foreach ($file in $files) {
            foreach ($cert in (ConvertTo-PemCertificateList -FilePath $file.FullName)) {
                [void]$allCerts.Add($cert)
            }
        }
    }

    if ($allCerts.Count -eq 0) { throw 'No certificates were found in the given path(s).' }
    return ,$allCerts.ToArray()
}

# ============================================================================
#  Single-device xAPI operations
# ============================================================================

function Test-RoomKitDevice {
    <# Reachability + auth probe. Returns product/software info on success. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [int]$TimeoutSec = 12,
        [int]$MaxAttempts = 2
    )

    $xml = Invoke-XapiRequest -Device $Device -Method GET -Path '/getxml?location=/Status/SystemUnit' `
        -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation 'Connectivity check'

    $product = ''
    $software = ''
    $uptime = ''
    try { $product = $xml.SelectSingleNode('//SystemUnit/ProductId').InnerText } catch { }
    try { $software = $xml.SelectSingleNode('//SystemUnit/Software/DisplayName').InnerText } catch { }
    try { $uptime = $xml.SelectSingleNode('//SystemUnit/Uptime').InnerText } catch { }

    return [pscustomobject]@{
        Product  = $product
        Software = $software
        Uptime   = $uptime
    }
}

function Get-RoomKitMacroList {
    <# Lists macros on the device (name + active flag where reported). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [int]$TimeoutSec = 20,
        [int]$MaxAttempts = 3
    )

    $body = '<Command><Macros><Macro><Get/></Macro></Macros></Command>'
    $xml = Invoke-XapiRequest -Device $Device -Body $body -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation 'List macros'

    $macros = New-Object System.Collections.Generic.List[object]
    if ($null -ne $xml) {
        foreach ($node in $xml.SelectNodes('//MacroGetResult/Macro')) {
            $name = ''
            $active = ''
            try { $name = $node.SelectSingleNode('./Name').InnerText } catch { }
            try { $active = $node.SelectSingleNode('./Active').InnerText } catch { }
            if ($name) {
                [void]$macros.Add([pscustomobject]@{ Name = $name; Active = $active })
            }
        }
    }
    return ,$macros.ToArray()
}

function Save-RoomKitMacro {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Code,
        [switch]$Transpile,
        [int]$TimeoutSec = 30,
        [int]$MaxAttempts = 3
    )

    $escapedName = [System.Security.SecurityElement]::Escape($Name)
    $escapedCode = [System.Security.SecurityElement]::Escape($Code)
    $transpileXml = ''
    if ($Transpile) { $transpileXml = '<Transpile>True</Transpile>' }

    # NOTE: the <body> element is case-sensitive on RoomOS - it must be lowercase.
    $body = "<Command><Macros><Macro><Save><Name>$escapedName</Name><OverWrite>True</OverWrite>$transpileXml<body>$escapedCode</body></Save></Macro></Macros></Command>"

    [void](Invoke-XapiRequest -Device $Device -Body $body -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation "Save macro '$Name'")
}

function Enable-RoomKitMacro {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [string]$Name,
        [int]$TimeoutSec = 20,
        [int]$MaxAttempts = 3
    )
    $escapedName = [System.Security.SecurityElement]::Escape($Name)
    $body = "<Command><Macros><Macro><Activate><Name>$escapedName</Name></Activate></Macro></Macros></Command>"
    [void](Invoke-XapiRequest -Device $Device -Body $body -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation "Activate macro '$Name'")
}

function Disable-RoomKitMacro {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [string]$Name,
        [int]$TimeoutSec = 20,
        [int]$MaxAttempts = 3
    )
    $escapedName = [System.Security.SecurityElement]::Escape($Name)
    $body = "<Command><Macros><Macro><Deactivate><Name>$escapedName</Name></Deactivate></Macro></Macros></Command>"
    [void](Invoke-XapiRequest -Device $Device -Body $body -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation "Deactivate macro '$Name'")
}

function Remove-RoomKitMacro {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [string]$Name,
        [int]$TimeoutSec = 20,
        [int]$MaxAttempts = 3
    )
    $escapedName = [System.Security.SecurityElement]::Escape($Name)
    $body = "<Command><Macros><Macro><Remove><Name>$escapedName</Name></Remove></Macro></Macros></Command>"
    [void](Invoke-XapiRequest -Device $Device -Body $body -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation "Remove macro '$Name'")
}

function Remove-AllRoomKitMacros {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [int]$TimeoutSec = 30,
        [int]$MaxAttempts = 3
    )
    $body = '<Command><Macros><Macro><RemoveAll/></Macro></Macros></Command>'
    [void](Invoke-XapiRequest -Device $Device -Body $body -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation 'Remove all macros')
}

function Set-RoomKitMacroMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [ValidateSet('On', 'Off')] [string]$Mode = 'On',
        [int]$TimeoutSec = 20,
        [int]$MaxAttempts = 3
    )
    $body = "<Configuration><Macros><Mode>$Mode</Mode></Macros></Configuration>"
    [void](Invoke-XapiRequest -Device $Device -Body $body -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation "Set macro mode $Mode")
}

function Set-RoomKitMacroAutoStart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [ValidateSet('On', 'Off')] [string]$Mode = 'On',
        [int]$TimeoutSec = 20,
        [int]$MaxAttempts = 3
    )
    $body = "<Configuration><Macros><AutoStart>$Mode</AutoStart></Macros></Configuration>"
    [void](Invoke-XapiRequest -Device $Device -Body $body -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation "Set macro autostart $Mode")
}

function Set-RoomKitTranspileEvaluation {
    <# Older firmware only. Callers should treat 'not supported' as benign. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [ValidateSet('True', 'False')] [string]$Value,
        [int]$TimeoutSec = 20,
        [int]$MaxAttempts = 3
    )
    $body = "<Configuration><Macros><EvaluateTranspiled>$Value</EvaluateTranspiled></Macros></Configuration>"
    [void](Invoke-XapiRequest -Device $Device -Body $body -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation "Set EvaluateTranspiled $Value")
}

function Restart-RoomKitMacroRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [int]$TimeoutSec = 30,
        [int]$MaxAttempts = 3
    )
    $body = '<Command><Macros><Runtime><Restart/></Runtime></Macros></Command>'
    [void](Invoke-XapiRequest -Device $Device -Body $body -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation 'Restart macro runtime')
}

function Add-RoomKitCACertificate {
    <# Installs a CA certificate (PEM text) into the device trust store via
       xCommand Security Certificates CA Add. Re-adding an existing
       certificate is reported as already-installed and treated as success. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [string]$Pem,
        [string]$Label = 'certificate',
        [int]$TimeoutSec = 30,
        [int]$MaxAttempts = 3
    )

    $escapedPem = [System.Security.SecurityElement]::Escape($Pem.Trim())
    $body = "<Command><Security><Certificates><CA><Add><body>$escapedPem</body></Add></CA></Certificates></Security></Command>"

    try {
        [void](Invoke-XapiRequest -Device $Device -Body $body -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation "Add CA certificate '$Label'")
        return 'Added'
    } catch {
        if ($_.Exception.Message -match '(?i)already (exists|installed|added)') {
            return 'AlreadyInstalled'
        }
        throw
    }
}

function Get-RoomKitCACertificateList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [int]$TimeoutSec = 20,
        [int]$MaxAttempts = 3
    )
    $body = '<Command><Security><Certificates><CA><Show/></CA></Certificates></Security></Command>'
    $xml = Invoke-XapiRequest -Device $Device -Body $body -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation 'List CA certificates'

    $certs = New-Object System.Collections.Generic.List[object]
    if ($null -ne $xml) {
        foreach ($node in $xml.SelectNodes('//Details')) {
            $subject = ''
            $fingerprint = ''
            try { $subject = $node.SelectSingleNode('./SubjectName').InnerText } catch { }
            try { $fingerprint = $node.SelectSingleNode('./Fingerprint').InnerText } catch { }
            if ($subject -or $fingerprint) {
                [void]$certs.Add([pscustomobject]@{ Subject = $subject; Fingerprint = $fingerprint })
            }
        }
    }
    return ,$certs.ToArray()
}

function Get-RoomKitPanelList {
    <# Lists UI extension panels (PanelId + Name where present). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [int]$TimeoutSec = 20,
        [int]$MaxAttempts = 3
    )
    $body = '<Command><UserInterface><Extensions><List/></Extensions></UserInterface></Command>'
    $xml = Invoke-XapiRequest -Device $Device -Body $body -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation 'List UI panels'

    $panels = New-Object System.Collections.Generic.List[object]
    if ($null -ne $xml) {
        foreach ($node in $xml.SelectNodes('//Panel')) {
            $panelId = ''
            $panelName = ''
            try { $panelId = $node.SelectSingleNode('./PanelId').InnerText } catch { }
            try { $panelName = $node.SelectSingleNode('./Name').InnerText } catch { }
            if ($panelId) {
                [void]$panels.Add([pscustomobject]@{ PanelId = $panelId; Name = $panelName })
            }
        }
    }
    return ,$panels.ToArray()
}

function Remove-RoomKitPanel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [string]$PanelId,
        [int]$TimeoutSec = 20,
        [int]$MaxAttempts = 3
    )
    $escapedId = [System.Security.SecurityElement]::Escape($PanelId)
    $body = "<Command><UserInterface><Extensions><Panel><Remove><PanelId>$escapedId</PanelId></Remove></Panel></Extensions></UserInterface></Command>"
    [void](Invoke-XapiRequest -Device $Device -Body $body -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation "Remove panel '$PanelId'")
}

function Clear-RoomKitPanels {
    <# Removes ALL UI extensions (panels/action buttons/web apps) from the device. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [int]$TimeoutSec = 30,
        [int]$MaxAttempts = 3
    )
    $body = '<Command><UserInterface><Extensions><Clear/></Extensions></UserInterface></Command>'
    [void](Invoke-XapiRequest -Device $Device -Body $body -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts -Operation 'Clear all UI extensions')
}

# ============================================================================
#  Per-device workflow workers (run inside runspaces by the fleet engine)
# ============================================================================

function New-DeviceLog {
    [CmdletBinding()]
    param()
    return New-Object System.Collections.Generic.List[string]
}

function Add-DeviceLogLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Log,
        [Parameter(Mandatory)] [string]$Message
    )
    [void]$Log.Add(('{0:HH:mm:ss} {1}' -f (Get-Date), $Message))
}

function New-DeviceResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [string]$Status = 'Failed',
        [int]$ItemsSucceeded = 0,
        [int]$ItemsFailed = 0,
        [string]$Detail = '',
        $Log = $null,
        [double]$DurationSec = 0,
        $Extra = $null
    )
    $logLines = @()
    if ($null -ne $Log) { $logLines = @($Log) }
    return [pscustomobject]@{
        Name             = $Device.Name
        Host             = $Device.Host
        Status           = $Status
        ItemsSucceeded   = $ItemsSucceeded
        ItemsFailed      = $ItemsFailed
        Detail           = $Detail
        LogLines         = $logLines
        DurationSec      = [Math]::Round($DurationSec, 1)
        Username         = $Device.Username
        Password         = $Device.Password
        CredentialSource = $Device.CredentialSource
        Extra            = $Extra
    }
}

function Invoke-DeviceMacroDeployment {
    <# Full deployment workflow for one device:
       connect -> macro mode on (+autostart) -> CA certs -> save macros ->
       activate -> restart runtime. Continues past per-item failures and
       reports Succeeded / Partial / Failed / Unreachable. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [object[]]$Macros = @(),
        [object[]]$Certificates = @(),
        [bool]$Activate = $true,
        [bool]$RestartRuntime = $true,
        [bool]$SetAutoStart = $true,
        [string]$EvaluateTranspiled = '',
        [bool]$Transpile = $false
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $log = New-DeviceLog
    $ok = 0
    $failed = 0
    $problems = New-Object System.Collections.Generic.List[string]

    # Per-device macro payload (e.g. Pexip OTJ ZIP matched by device name)
    # overrides the fleet-wide macro list.
    $deviceMacroProperty = $Device.PSObject.Properties['Macros']
    if ($null -ne $deviceMacroProperty -and $null -ne $deviceMacroProperty.Value -and @($deviceMacroProperty.Value).Count -gt 0) {
        $Macros = @($deviceMacroProperty.Value)
    }

    # 1. Connectivity / auth check.
    try {
        $info = Test-RoomKitDevice -Device $Device
        Add-DeviceLogLine -Log $log -Message "Connected: $($info.Product) ($($info.Software))"
    } catch {
        Add-DeviceLogLine -Log $log -Message "UNREACHABLE: $($_.Exception.Message)"
        return New-DeviceResult -Device $Device -Status 'Unreachable' -Detail $_.Exception.Message -Log $log -DurationSec $stopwatch.Elapsed.TotalSeconds
    }

    # 2. Macro mode + autostart (required before saving/activating macros).
    if ($Macros.Count -gt 0) {
        try {
            Set-RoomKitMacroMode -Device $Device -Mode On
            Add-DeviceLogLine -Log $log -Message 'Macro mode: On'
        } catch {
            Add-DeviceLogLine -Log $log -Message "FAILED to enable macro mode: $($_.Exception.Message)"
            return New-DeviceResult -Device $Device -Status 'Failed' -Detail "Could not enable macro mode: $($_.Exception.Message)" -Log $log -DurationSec $stopwatch.Elapsed.TotalSeconds
        }
        if ($SetAutoStart) {
            try {
                Set-RoomKitMacroAutoStart -Device $Device -Mode On
                Add-DeviceLogLine -Log $log -Message 'Macro autostart: On'
            } catch {
                Add-DeviceLogLine -Log $log -Message "WARNING: could not set macro autostart: $($_.Exception.Message)"
            }
        }
        if ($EvaluateTranspiled -eq 'True' -or $EvaluateTranspiled -eq 'False') {
            try {
                Set-RoomKitTranspileEvaluation -Device $Device -Value $EvaluateTranspiled
                Add-DeviceLogLine -Log $log -Message "EvaluateTranspiled: $EvaluateTranspiled"
            } catch {
                # Newer firmware removed this setting - benign.
                Add-DeviceLogLine -Log $log -Message "NOTE: EvaluateTranspiled not applied (likely unsupported firmware): $($_.Exception.Message)"
            }
        }
    }

    # 3. CA certificates.
    foreach ($cert in $Certificates) {
        try {
            $outcome = Add-RoomKitCACertificate -Device $Device -Pem $cert.Pem -Label $cert.Label
            Add-DeviceLogLine -Log $log -Message "CA certificate '$($cert.Label)' ($($cert.Subject)): $outcome"
            $ok++
        } catch {
            Add-DeviceLogLine -Log $log -Message "FAILED CA certificate '$($cert.Label)': $($_.Exception.Message)"
            [void]$problems.Add("cert '$($cert.Label)': $($_.Exception.Message)")
            $failed++
        }
    }

    # 4. Macros: save then activate.
    $savedAny = $false
    foreach ($macro in $Macros) {
        try {
            if ($Transpile) {
                Save-RoomKitMacro -Device $Device -Name $macro.Name -Code $macro.Code -Transpile
            } else {
                Save-RoomKitMacro -Device $Device -Name $macro.Name -Code $macro.Code
            }
            Add-DeviceLogLine -Log $log -Message "Saved macro '$($macro.Name)'"
            $savedAny = $true
            if ($Activate) {
                Enable-RoomKitMacro -Device $Device -Name $macro.Name
                Add-DeviceLogLine -Log $log -Message "Activated macro '$($macro.Name)'"
            }
            $ok++
        } catch {
            Add-DeviceLogLine -Log $log -Message "FAILED macro '$($macro.Name)': $($_.Exception.Message)"
            [void]$problems.Add("macro '$($macro.Name)': $($_.Exception.Message)")
            $failed++
        }
    }

    # 5. Restart the macro runtime once, if anything was deployed.
    if ($RestartRuntime -and $savedAny) {
        try {
            Restart-RoomKitMacroRuntime -Device $Device
            Add-DeviceLogLine -Log $log -Message 'Macro runtime restarted'
        } catch {
            Add-DeviceLogLine -Log $log -Message "WARNING: macro runtime restart failed: $($_.Exception.Message)"
            [void]$problems.Add("runtime restart: $($_.Exception.Message)")
        }
    }

    $status = 'Succeeded'
    if ($failed -gt 0 -and $ok -gt 0) { $status = 'Partial' }
    elseif ($failed -gt 0 -and $ok -eq 0) { $status = 'Failed' }

    $detail = "$ok item(s) deployed"
    if ($problems.Count -gt 0) { $detail += '; problems: ' + ($problems -join ' | ') }

    return New-DeviceResult -Device $Device -Status $status -ItemsSucceeded $ok -ItemsFailed $failed -Detail $detail -Log $log -DurationSec $stopwatch.Elapsed.TotalSeconds
}

function Invoke-DeviceCertificateDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [object[]]$Certificates
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $log = New-DeviceLog
    $ok = 0
    $failed = 0
    $problems = New-Object System.Collections.Generic.List[string]

    try {
        $info = Test-RoomKitDevice -Device $Device
        Add-DeviceLogLine -Log $log -Message "Connected: $($info.Product) ($($info.Software))"
    } catch {
        Add-DeviceLogLine -Log $log -Message "UNREACHABLE: $($_.Exception.Message)"
        return New-DeviceResult -Device $Device -Status 'Unreachable' -Detail $_.Exception.Message -Log $log -DurationSec $stopwatch.Elapsed.TotalSeconds
    }

    foreach ($cert in $Certificates) {
        try {
            $outcome = Add-RoomKitCACertificate -Device $Device -Pem $cert.Pem -Label $cert.Label
            Add-DeviceLogLine -Log $log -Message "CA certificate '$($cert.Label)' ($($cert.Subject)): $outcome"
            $ok++
        } catch {
            Add-DeviceLogLine -Log $log -Message "FAILED CA certificate '$($cert.Label)': $($_.Exception.Message)"
            [void]$problems.Add("cert '$($cert.Label)': $($_.Exception.Message)")
            $failed++
        }
    }

    $status = 'Succeeded'
    if ($failed -gt 0 -and $ok -gt 0) { $status = 'Partial' }
    elseif ($failed -gt 0 -and $ok -eq 0) { $status = 'Failed' }

    $detail = "$ok certificate(s) installed"
    if ($problems.Count -gt 0) { $detail += '; problems: ' + ($problems -join ' | ') }

    return New-DeviceResult -Device $Device -Status $status -ItemsSucceeded $ok -ItemsFailed $failed -Detail $detail -Log $log -DurationSec $stopwatch.Elapsed.TotalSeconds
}

function Invoke-DeviceMacroRemoval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [string[]]$MacroNames = @(),
        [bool]$AllMacros = $false,
        [string[]]$PanelIds = @(),
        [bool]$AllPanels = $false,
        [bool]$RestartRuntime = $true
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $log = New-DeviceLog
    $ok = 0
    $failed = 0
    $problems = New-Object System.Collections.Generic.List[string]

    try {
        $info = Test-RoomKitDevice -Device $Device
        Add-DeviceLogLine -Log $log -Message "Connected: $($info.Product) ($($info.Software))"
    } catch {
        Add-DeviceLogLine -Log $log -Message "UNREACHABLE: $($_.Exception.Message)"
        return New-DeviceResult -Device $Device -Status 'Unreachable' -Detail $_.Exception.Message -Log $log -DurationSec $stopwatch.Elapsed.TotalSeconds
    }

    $removedAnyMacro = $false

    if ($AllMacros) {
        try {
            Remove-AllRoomKitMacros -Device $Device
            Add-DeviceLogLine -Log $log -Message 'Removed ALL macros'
            $removedAnyMacro = $true
            $ok++
        } catch {
            Add-DeviceLogLine -Log $log -Message "FAILED to remove all macros: $($_.Exception.Message)"
            [void]$problems.Add("remove all macros: $($_.Exception.Message)")
            $failed++
        }
    } elseif ($MacroNames.Count -gt 0) {
        $existing = @()
        try {
            $existing = @((Get-RoomKitMacroList -Device $Device) | ForEach-Object { $_.Name })
        } catch {
            Add-DeviceLogLine -Log $log -Message "WARNING: could not list macros first: $($_.Exception.Message)"
            $existing = $null
        }

        foreach ($name in $MacroNames) {
            if ($null -ne $existing -and $existing -notcontains $name) {
                Add-DeviceLogLine -Log $log -Message "Macro '$name' not present - nothing to remove"
                $ok++
                continue
            }
            try {
                try { Disable-RoomKitMacro -Device $Device -Name $name } catch { }
                Remove-RoomKitMacro -Device $Device -Name $name
                Add-DeviceLogLine -Log $log -Message "Removed macro '$name'"
                $removedAnyMacro = $true
                $ok++
            } catch {
                Add-DeviceLogLine -Log $log -Message "FAILED to remove macro '$name': $($_.Exception.Message)"
                [void]$problems.Add("macro '$name': $($_.Exception.Message)")
                $failed++
            }
        }
    }

    if ($AllPanels) {
        try {
            Clear-RoomKitPanels -Device $Device
            Add-DeviceLogLine -Log $log -Message 'Cleared ALL UI extensions'
            $ok++
        } catch {
            Add-DeviceLogLine -Log $log -Message "FAILED to clear UI extensions: $($_.Exception.Message)"
            [void]$problems.Add("clear panels: $($_.Exception.Message)")
            $failed++
        }
    } elseif ($PanelIds.Count -gt 0) {
        foreach ($panelId in $PanelIds) {
            try {
                Remove-RoomKitPanel -Device $Device -PanelId $panelId
                Add-DeviceLogLine -Log $log -Message "Removed panel '$panelId'"
                $ok++
            } catch {
                if ($_.Exception.Message -match '(?i)does not exist|not found') {
                    Add-DeviceLogLine -Log $log -Message "Panel '$panelId' not present - nothing to remove"
                    $ok++
                } else {
                    Add-DeviceLogLine -Log $log -Message "FAILED to remove panel '$panelId': $($_.Exception.Message)"
                    [void]$problems.Add("panel '$panelId': $($_.Exception.Message)")
                    $failed++
                }
            }
        }
    }

    if ($RestartRuntime -and $removedAnyMacro) {
        try {
            Restart-RoomKitMacroRuntime -Device $Device
            Add-DeviceLogLine -Log $log -Message 'Macro runtime restarted'
        } catch {
            Add-DeviceLogLine -Log $log -Message "WARNING: macro runtime restart failed: $($_.Exception.Message)"
            [void]$problems.Add("runtime restart: $($_.Exception.Message)")
        }
    }

    $status = 'Succeeded'
    if ($failed -gt 0 -and $ok -gt 0) { $status = 'Partial' }
    elseif ($failed -gt 0 -and $ok -eq 0) { $status = 'Failed' }

    $detail = "$ok removal step(s) completed"
    if ($problems.Count -gt 0) { $detail += '; problems: ' + ($problems -join ' | ') }

    return New-DeviceResult -Device $Device -Status $status -ItemsSucceeded $ok -ItemsFailed $failed -Detail $detail -Log $log -DurationSec $stopwatch.Elapsed.TotalSeconds
}

function Invoke-DeviceAudit {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Device)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $log = New-DeviceLog

    try {
        $info = Test-RoomKitDevice -Device $Device
        Add-DeviceLogLine -Log $log -Message "Connected: $($info.Product) ($($info.Software))"
    } catch {
        Add-DeviceLogLine -Log $log -Message "UNREACHABLE: $($_.Exception.Message)"
        return New-DeviceResult -Device $Device -Status 'Unreachable' -Detail $_.Exception.Message -Log $log -DurationSec $stopwatch.Elapsed.TotalSeconds
    }

    $macroMode = ''
    try {
        $configXml = Invoke-XapiRequest -Device $Device -Method GET -Path '/getxml?location=/Configuration/Macros' -Operation 'Read macro config'
        if ($null -ne $configXml) {
            $modeNode = $configXml.SelectSingleNode('//Macros/Mode')
            if ($null -ne $modeNode) { $macroMode = $modeNode.InnerText }
        }
    } catch {
        Add-DeviceLogLine -Log $log -Message "WARNING: could not read macro config: $($_.Exception.Message)"
    }

    $macros = @()
    try {
        $macros = @(Get-RoomKitMacroList -Device $Device)
    } catch {
        Add-DeviceLogLine -Log $log -Message "WARNING: could not list macros: $($_.Exception.Message)"
    }

    $panels = @()
    try {
        $panels = @(Get-RoomKitPanelList -Device $Device)
    } catch {
        Add-DeviceLogLine -Log $log -Message "WARNING: could not list panels: $($_.Exception.Message)"
    }

    $macroText = ($macros | ForEach-Object {
        if ($_.Active -eq 'True') { "$($_.Name) [active]" } else { $_.Name }
    }) -join ', '
    $panelText = ($panels | ForEach-Object { $_.PanelId }) -join ', '

    Add-DeviceLogLine -Log $log -Message "Macro mode: $macroMode | Macros: $macroText | Panels: $panelText"

    $extra = [pscustomobject]@{
        Product   = $info.Product
        Software  = $info.Software
        MacroMode = $macroMode
        Macros    = $macroText
        Panels    = $panelText
    }

    return New-DeviceResult -Device $Device -Status 'Succeeded' -ItemsSucceeded $macros.Count -Detail "mode=$macroMode; $($macros.Count) macro(s); $($panels.Count) panel(s)" -Log $log -DurationSec $stopwatch.Elapsed.TotalSeconds -Extra $extra
}

function Invoke-DeviceConnectivityTest {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Device)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $log = New-DeviceLog

    try {
        $info = Test-RoomKitDevice -Device $Device
        Add-DeviceLogLine -Log $log -Message "Connected: $($info.Product) ($($info.Software))"
        return New-DeviceResult -Device $Device -Status 'Succeeded' -ItemsSucceeded 1 -Detail "$($info.Product) ($($info.Software))" -Log $log -DurationSec $stopwatch.Elapsed.TotalSeconds
    } catch {
        Add-DeviceLogLine -Log $log -Message "UNREACHABLE: $($_.Exception.Message)"
        return New-DeviceResult -Device $Device -Status 'Unreachable' -ItemsFailed 1 -Detail $_.Exception.Message -Log $log -DurationSec $stopwatch.Elapsed.TotalSeconds
    }
}

# ============================================================================
#  Fleet engine: parallel execution over many devices with live progress,
#  consolidated logging, results CSV, and a failed-devices retry CSV.
# ============================================================================

function Invoke-FleetOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Devices,
        [Parameter(Mandatory)] [string]$WorkerFunction,
        [hashtable]$WorkerArguments = @{},
        [ValidateRange(1, 100)] [int]$ThrottleLimit = 20,
        [string]$OperationName = 'FleetOperation',
        [string]$LogDirectory
    )

    if (-not $LogDirectory) { $LogDirectory = Join-Path $script:ModuleRoot 'logs' }
    New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

    $timestamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logFile     = Join-Path $LogDirectory ("{0}_{1}.log" -f $OperationName, $timestamp)
    $resultsFile = Join-Path $LogDirectory ("{0}_{1}_results.csv" -f $OperationName, $timestamp)
    $failedFile  = Join-Path $LogDirectory ("{0}_{1}_failed.csv" -f $OperationName, $timestamp)

    $runStart = Get-Date
    Add-Content -Path $logFile -Value ("{0:yyyy-MM-dd HH:mm:ss} === {1} started: {2} device(s), throttle {3} ===" -f $runStart, $OperationName, $Devices.Count, $ThrottleLimit)

    # Each runspace in the pool loads this module once, so workers and all
    # their helpers are available without per-job imports.
    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    [void]$sessionState.ImportPSModule(@($script:ModuleFilePath))
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool($sessionState)
    [void]$pool.SetMinRunspaces(1)
    [void]$pool.SetMaxRunspaces($ThrottleLimit)
    $pool.Open()

    $dispatchScript = {
        param($FunctionName, $Device, $Arguments)
        try {
            & $FunctionName -Device $Device @Arguments
        } catch {
            [pscustomobject]@{
                Name             = $Device.Name
                Host             = $Device.Host
                Status           = 'Failed'
                ItemsSucceeded   = 0
                ItemsFailed      = 0
                Detail           = "Unhandled worker error: $($_.Exception.Message)"
                LogLines         = @("Unhandled worker error: $($_.Exception.Message)")
                DurationSec      = 0
                Username         = $Device.Username
                Password         = $Device.Password
                CredentialSource = $Device.CredentialSource
                Extra            = $null
            }
        }
    }

    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($device in $Devices) {
        $shell = [System.Management.Automation.PowerShell]::Create()
        $shell.RunspacePool = $pool
        [void]$shell.AddScript($dispatchScript).AddArgument($WorkerFunction).AddArgument($device).AddArgument($WorkerArguments)
        [void]$pending.Add([pscustomobject]@{
            Shell  = $shell
            Handle = $shell.BeginInvoke()
            Device = $device
        })
    }

    $results = New-Object System.Collections.Generic.List[object]
    $total = $Devices.Count
    $done = 0

    try {
        while ($pending.Count -gt 0) {
            $finished = @($pending | Where-Object { $_.Handle.IsCompleted })
            if ($finished.Count -eq 0) {
                Start-Sleep -Milliseconds 250
                continue
            }
            foreach ($job in $finished) {
                [void]$pending.Remove($job)
                $result = $null
                $endInvokeError = $null
                try {
                    $output = $job.Shell.EndInvoke($job.Handle)
                    $result = @($output) | Where-Object { $null -ne $_ } | Select-Object -Last 1
                } catch {
                    $result = $null
                    $endInvokeError = $_.Exception.Message
                }
                if ($null -eq $result) {
                    $reason = 'worker produced no result'
                    if ($endInvokeError) { $reason = $endInvokeError }
                    $result = [pscustomobject]@{
                        Name             = $job.Device.Name
                        Host             = $job.Device.Host
                        Status           = 'Failed'
                        ItemsSucceeded   = 0
                        ItemsFailed      = 0
                        Detail           = $reason
                        LogLines         = @($reason)
                        DurationSec      = 0
                        Username         = $job.Device.Username
                        Password         = $job.Device.Password
                        CredentialSource = $job.Device.CredentialSource
                        Extra            = $null
                    }
                }
                $job.Shell.Dispose()

                $done++
                [void]$results.Add($result)

                # Consolidated log: one block per device as it completes.
                $block = New-Object System.Text.StringBuilder
                foreach ($line in $result.LogLines) {
                    [void]$block.AppendLine("[$($result.Name) / $($result.Host)] $line")
                }
                [void]$block.AppendLine("[$($result.Name) / $($result.Host)] RESULT: $($result.Status) in $($result.DurationSec)s - $($result.Detail)")
                Add-Content -Path $logFile -Value $block.ToString().TrimEnd()

                $color = 'Green'
                if ($result.Status -eq 'Partial') { $color = 'Yellow' }
                elseif ($result.Status -eq 'Skipped') { $color = 'DarkYellow' }
                elseif ($result.Status -ne 'Succeeded') { $color = 'Red' }
                Write-Host ("[{0}/{1}] {2,-12} {3} ({4}) - {5}" -f $done, $total, $result.Status.ToUpper(), $result.Name, $result.Host, $result.Detail) -ForegroundColor $color

                Write-Progress -Activity $OperationName -Status "$done of $total devices processed" -PercentComplete ([int](100 * $done / $total))
            }
        }
    } finally {
        Write-Progress -Activity $OperationName -Completed
        foreach ($job in $pending) {
            try { $job.Shell.Stop() } catch { }
            try { $job.Shell.Dispose() } catch { }
        }
        $pool.Close()
        $pool.Dispose()
    }

    # Results CSV (no passwords, no raw log lines).
    $results |
        Select-Object Name, Host, Status, ItemsSucceeded, ItemsFailed, DurationSec, Detail |
        Export-Csv -Path $resultsFile -NoTypeInformation -Encoding UTF8

    # Failed-device CSV, directly reusable as the input CSV for a retry run.
    # Passwords are only written back if they originally came from the CSV.
    $failedResults = @($results | Where-Object { $_.Status -in 'Failed', 'Unreachable', 'Partial' })
    $failedFileOut = ''
    if ($failedResults.Count -gt 0) {
        $failedResults | ForEach-Object {
            $pw = ''
            $user = ''
            if ($_.CredentialSource -eq 'csv') {
                $user = $_.Username
                $pw = $_.Password
            }
            [pscustomobject]@{ name = $_.Name; host = $_.Host; username = $user; password = $pw }
        } | Export-Csv -Path $failedFile -NoTypeInformation -Encoding UTF8
        $failedFileOut = $failedFile
    }

    $summaryCounts = @{}
    foreach ($state in 'Succeeded', 'Partial', 'Failed', 'Unreachable', 'Skipped') {
        $summaryCounts[$state] = @($results | Where-Object { $_.Status -eq $state }).Count
    }
    $elapsed = (Get-Date) - $runStart
    Add-Content -Path $logFile -Value ("{0:yyyy-MM-dd HH:mm:ss} === {1} finished in {2:n0}s: {3} OK, {4} partial, {5} failed, {6} unreachable, {7} skipped ===" -f (Get-Date), $OperationName, $elapsed.TotalSeconds, $summaryCounts['Succeeded'], $summaryCounts['Partial'], $summaryCounts['Failed'], $summaryCounts['Unreachable'], $summaryCounts['Skipped'])

    return [pscustomobject]@{
        Operation   = $OperationName
        Total       = $total
        Succeeded   = $summaryCounts['Succeeded']
        Partial     = $summaryCounts['Partial']
        Failed      = $summaryCounts['Failed']
        Unreachable = $summaryCounts['Unreachable']
        Skipped     = $summaryCounts['Skipped']
        DurationSec = [Math]::Round($elapsed.TotalSeconds, 1)
        LogFile     = $logFile
        ResultsFile = $resultsFile
        FailedFile  = $failedFileOut
        Results     = $results.ToArray()
    }
}

function Show-FleetSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Summary)

    Write-Host ''
    Write-Host ('=' * 70)
    Write-Host "  $($Summary.Operation) complete in $($Summary.DurationSec)s"
    Write-Host ('=' * 70)
    Write-Host ("  Devices:     {0}" -f $Summary.Total)
    Write-Host ("  Succeeded:   {0}" -f $Summary.Succeeded) -ForegroundColor Green
    if ($Summary.Partial -gt 0)     { Write-Host ("  Partial:     {0}" -f $Summary.Partial) -ForegroundColor Yellow }
    if ($Summary.Failed -gt 0)      { Write-Host ("  Failed:      {0}" -f $Summary.Failed) -ForegroundColor Red }
    if ($Summary.Unreachable -gt 0) { Write-Host ("  Unreachable: {0}" -f $Summary.Unreachable) -ForegroundColor Red }
    if ($Summary.Skipped -gt 0)     { Write-Host ("  Skipped:     {0}" -f $Summary.Skipped) -ForegroundColor DarkYellow }
    Write-Host ''
    Write-Host "  Log:     $($Summary.LogFile)"
    Write-Host "  Results: $($Summary.ResultsFile)"
    if ($Summary.FailedFile) {
        Write-Host "  Retry:   $($Summary.FailedFile)" -ForegroundColor Yellow
        Write-Host '           (use this file as the device CSV to retry only the failures)' -ForegroundColor Yellow
    }
    Write-Host ('=' * 70)
    Write-Host ''
}

# ============================================================================
#  Public fleet entry points
# ============================================================================

function Invoke-MacroDeployment {
    <#
    .SYNOPSIS
        Deploys macros (and optionally CA certificates) to one or many devices.
    .PARAMETER MacroPath
        One or more sources: a single .js file, a directory of .js files,
        and/or .zip packages. All resolved macros go to every device.
    .PARAMETER PerDeviceZipDirectory
        Alternative mode (e.g. Pexip One-Touch-Join): a directory of per-device
        .zip packages matched to each device by name
        (*<devicename-without-spaces>*.zip). Devices without a match are skipped.
    .PARAMETER CertificatePath
        Optional CA certificate files (.pem/.crt/.cer/.der) or directories,
        installed into each device's CA trust store before the macros.
    #>
    [CmdletBinding(DefaultParameterSetName = 'SharedMacros')]
    param(
        [Parameter(Mandatory)] [string]$DeviceCsv,
        [Parameter(Mandatory, ParameterSetName = 'SharedMacros')] [string[]]$MacroPath,
        [Parameter(Mandatory, ParameterSetName = 'PerDeviceZip')] [string]$PerDeviceZipDirectory,
        [string[]]$CertificatePath,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$ThrottleLimit = 20,
        [switch]$NoActivate,
        [switch]$NoRuntimeRestart,
        [switch]$NoAutoStart,
        [switch]$Transpile,
        [ValidateSet('', 'True', 'False')] [string]$EvaluateTranspiled = '',
        [string]$LogDirectory,
        [switch]$Force
    )

    $devices = Import-DeviceList -Path $DeviceCsv -Credential $Credential
    $tempDirs = New-Object System.Collections.Generic.List[string]

    try {
        $certificates = @()
        if ($CertificatePath) {
            $certificates = @(Resolve-CertificateSource -Path $CertificatePath)
        }

        $macros = @()
        if ($PSCmdlet.ParameterSetName -eq 'SharedMacros') {
            $macros = @(Resolve-MacroSource -Path $MacroPath -TempDirectories $tempDirs)
        } else {
            # Per-device ZIP matching (Pexip OTJ style: one package per room).
            $zipFiles = @(Get-ChildItem -LiteralPath $PerDeviceZipDirectory -Filter *.zip -File)
            if ($zipFiles.Count -eq 0) { throw "No .zip packages found in: $PerDeviceZipDirectory" }

            $matched = New-Object System.Collections.Generic.List[object]
            $skipped = New-Object System.Collections.Generic.List[string]
            foreach ($device in $devices) {
                $normalized = ($device.Name -replace '\s', '').ToLower()
                $zipMatch = $zipFiles | Where-Object { $_.Name.ToLower() -like "*$normalized*" } | Select-Object -First 1
                if ($null -eq $zipMatch) {
                    [void]$skipped.Add($device.Name)
                    continue
                }
                $deviceMacros = @(Resolve-MacroSource -Path @($zipMatch.FullName) -TempDirectories $tempDirs)
                $device | Add-Member -NotePropertyName Macros -NotePropertyValue $deviceMacros -Force
                [void]$matched.Add($device)
            }
            if ($skipped.Count -gt 0) {
                Write-Warning "$($skipped.Count) device(s) have no matching ZIP and will be skipped: $($skipped -join ', ')"
            }
            if ($matched.Count -eq 0) { throw 'No devices matched any ZIP package - nothing to do.' }
            $devices = $matched.ToArray()
        }

        Write-Host ''
        Write-Host 'Deployment plan:' -ForegroundColor Cyan
        Write-Host "  Devices:      $($devices.Count)"
        if ($PSCmdlet.ParameterSetName -eq 'SharedMacros') {
            Write-Host "  Macros:       $($macros.Count) ($(@($macros | ForEach-Object { $_.Name }) -join ', '))"
        } else {
            Write-Host '  Macros:       per-device ZIP packages'
        }
        Write-Host "  Certificates: $($certificates.Count)"
        Write-Host "  Activate macros: $(-not $NoActivate) | Restart runtime: $(-not $NoRuntimeRestart) | Parallelism: $ThrottleLimit"
        Write-Host ''

        if (-not $Force) {
            $answer = Read-Host 'Proceed? (y/n)'
            if ($answer -ne 'y') {
                Write-Host 'Cancelled.'
                return
            }
        }

        $workerArgs = @{
            Macros             = $macros
            Certificates       = $certificates
            Activate           = (-not $NoActivate)
            RestartRuntime     = (-not $NoRuntimeRestart)
            SetAutoStart       = (-not $NoAutoStart)
            EvaluateTranspiled = $EvaluateTranspiled
            Transpile          = [bool]$Transpile
        }

        $summary = Invoke-FleetOperation -Devices $devices -WorkerFunction 'Invoke-DeviceMacroDeployment' `
            -WorkerArguments $workerArgs -ThrottleLimit $ThrottleLimit -OperationName 'MacroDeployment' -LogDirectory $LogDirectory
        Show-FleetSummary -Summary $summary
        return $summary
    } finally {
        foreach ($dir in $tempDirs) {
            try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Invoke-CertificateDeployment {
    <# Installs CA certificates into the trust store of every device. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$DeviceCsv,
        [Parameter(Mandatory)] [string[]]$CertificatePath,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$ThrottleLimit = 20,
        [string]$LogDirectory,
        [switch]$Force
    )

    $devices = Import-DeviceList -Path $DeviceCsv -Credential $Credential
    $certificates = @(Resolve-CertificateSource -Path $CertificatePath)

    Write-Host ''
    Write-Host 'Certificate deployment plan:' -ForegroundColor Cyan
    Write-Host "  Devices:      $($devices.Count)"
    foreach ($cert in $certificates) {
        Write-Host "  Certificate:  $($cert.Label)  $($cert.Subject)"
    }
    Write-Host ''

    if (-not $Force) {
        $answer = Read-Host 'Proceed? (y/n)'
        if ($answer -ne 'y') {
            Write-Host 'Cancelled.'
            return
        }
    }

    $summary = Invoke-FleetOperation -Devices $devices -WorkerFunction 'Invoke-DeviceCertificateDeployment' `
        -WorkerArguments @{ Certificates = $certificates } -ThrottleLimit $ThrottleLimit `
        -OperationName 'CertificateDeployment' -LogDirectory $LogDirectory
    Show-FleetSummary -Summary $summary
    return $summary
}

function Invoke-MacroRemoval {
    <# Removes macros (specific names or all) and optionally UI panels, then
       restarts the macro runtime. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$DeviceCsv,
        [string[]]$MacroName = @(),
        [switch]$AllMacros,
        [string[]]$PanelId = @(),
        [switch]$AllPanels,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$ThrottleLimit = 20,
        [switch]$NoRuntimeRestart,
        [string]$LogDirectory,
        [switch]$Force
    )

    if (-not $AllMacros -and $MacroName.Count -eq 0 -and -not $AllPanels -and $PanelId.Count -eq 0) {
        throw 'Nothing to remove: specify -MacroName, -AllMacros, -PanelId and/or -AllPanels.'
    }

    $devices = Import-DeviceList -Path $DeviceCsv -Credential $Credential

    Write-Host ''
    Write-Host 'Removal plan:' -ForegroundColor Cyan
    Write-Host "  Devices: $($devices.Count)"
    if ($AllMacros) { Write-Host '  Macros:  ALL MACROS WILL BE REMOVED' -ForegroundColor Red }
    elseif ($MacroName.Count -gt 0) { Write-Host "  Macros:  $($MacroName -join ', ')" }
    if ($AllPanels) { Write-Host '  Panels:  ALL UI EXTENSIONS WILL BE REMOVED' -ForegroundColor Red }
    elseif ($PanelId.Count -gt 0) { Write-Host "  Panels:  $($PanelId -join ', ')" }
    Write-Host ''

    if (-not $Force) {
        $confirmWord = 'y'
        $prompt = 'Proceed? (y/n)'
        if ($AllMacros -or $AllPanels) {
            $confirmWord = 'remove'
            $prompt = "This is destructive across $($devices.Count) device(s). Type 'remove' to proceed"
        }
        $answer = Read-Host $prompt
        if ($answer -ne $confirmWord) {
            Write-Host 'Cancelled.'
            return
        }
    }

    $workerArgs = @{
        MacroNames     = $MacroName
        AllMacros      = [bool]$AllMacros
        PanelIds       = $PanelId
        AllPanels      = [bool]$AllPanels
        RestartRuntime = (-not $NoRuntimeRestart)
    }

    $summary = Invoke-FleetOperation -Devices $devices -WorkerFunction 'Invoke-DeviceMacroRemoval' `
        -WorkerArguments $workerArgs -ThrottleLimit $ThrottleLimit -OperationName 'MacroRemoval' -LogDirectory $LogDirectory
    Show-FleetSummary -Summary $summary
    return $summary
}

function Invoke-PanelRemoval {
    <# Removes UI extension panels only (no macro changes). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$DeviceCsv,
        [string[]]$PanelId = @(),
        [switch]$AllPanels,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$ThrottleLimit = 20,
        [string]$LogDirectory,
        [switch]$Force
    )

    if (-not $AllPanels -and $PanelId.Count -eq 0) {
        throw 'Specify -PanelId (one or more IDs) or -AllPanels.'
    }

    Invoke-MacroRemoval -DeviceCsv $DeviceCsv -PanelId $PanelId -AllPanels:$AllPanels -Credential $Credential `
        -ThrottleLimit $ThrottleLimit -NoRuntimeRestart -LogDirectory $LogDirectory -Force:$Force
}

function Get-FleetInventory {
    <# Audits every device: product, software, macro mode, macro list (with
       active state) and panel list. Writes an inventory CSV. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$DeviceCsv,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$ThrottleLimit = 20,
        [string]$LogDirectory,
        [string]$OutputCsv
    )

    $devices = Import-DeviceList -Path $DeviceCsv -Credential $Credential

    $summary = Invoke-FleetOperation -Devices $devices -WorkerFunction 'Invoke-DeviceAudit' `
        -WorkerArguments @{} -ThrottleLimit $ThrottleLimit -OperationName 'FleetInventory' -LogDirectory $LogDirectory

    if (-not $OutputCsv) {
        $OutputCsv = $summary.ResultsFile -replace '_results\.csv$', '_inventory.csv'
    }

    $summary.Results | ForEach-Object {
        $extra = $_.Extra
        $product = ''
        $software = ''
        $macroMode = ''
        $macroText = ''
        $panelText = ''
        if ($null -ne $extra) {
            $product = $extra.Product
            $software = $extra.Software
            $macroMode = $extra.MacroMode
            $macroText = $extra.Macros
            $panelText = $extra.Panels
        }
        [pscustomobject]@{
            Name      = $_.Name
            Host      = $_.Host
            Status    = $_.Status
            Product   = $product
            Software  = $software
            MacroMode = $macroMode
            Macros    = $macroText
            Panels    = $panelText
            Detail    = $_.Detail
        }
    } | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

    Show-FleetSummary -Summary $summary
    Write-Host "  Inventory report: $OutputCsv" -ForegroundColor Cyan
    Write-Host ''
    return $summary
}

function Test-FleetConnectivity {
    <# Dry run: verifies every device in the CSV is reachable and the
       credentials work, without changing anything. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$DeviceCsv,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$ThrottleLimit = 20,
        [string]$LogDirectory
    )

    $devices = Import-DeviceList -Path $DeviceCsv -Credential $Credential

    $summary = Invoke-FleetOperation -Devices $devices -WorkerFunction 'Invoke-DeviceConnectivityTest' `
        -WorkerArguments @{} -ThrottleLimit $ThrottleLimit -OperationName 'ConnectivityTest' -LogDirectory $LogDirectory
    Show-FleetSummary -Summary $summary
    return $summary
}

# ============================================================================
#  Exports
# ============================================================================

Export-ModuleMember -Function @(
    # Fleet entry points
    'Invoke-MacroDeployment'
    'Invoke-CertificateDeployment'
    'Invoke-MacroRemoval'
    'Invoke-PanelRemoval'
    'Get-FleetInventory'
    'Test-FleetConnectivity'
    'Invoke-FleetOperation'
    'Show-FleetSummary'
    # Device workers (needed inside runspaces)
    'Invoke-DeviceMacroDeployment'
    'Invoke-DeviceCertificateDeployment'
    'Invoke-DeviceMacroRemoval'
    'Invoke-DeviceAudit'
    'Invoke-DeviceConnectivityTest'
    # Building blocks
    'Import-DeviceList'
    'Resolve-MacroSource'
    'Resolve-CertificateSource'
    'ConvertTo-PemCertificateList'
    'Invoke-XapiRequest'
    'Test-RoomKitDevice'
    'Get-RoomKitMacroList'
    'Save-RoomKitMacro'
    'Enable-RoomKitMacro'
    'Disable-RoomKitMacro'
    'Remove-RoomKitMacro'
    'Remove-AllRoomKitMacros'
    'Set-RoomKitMacroMode'
    'Set-RoomKitMacroAutoStart'
    'Set-RoomKitTranspileEvaluation'
    'Restart-RoomKitMacroRuntime'
    'Add-RoomKitCACertificate'
    'Get-RoomKitCACertificateList'
    'Get-RoomKitPanelList'
    'Remove-RoomKitPanel'
    'Clear-RoomKitPanels'
    # Helpers used by workers
    'New-DeviceLog'
    'Add-DeviceLogLine'
    'New-DeviceResult'
    'Initialize-XapiTransport'
    'Get-XapiFailureInfo'
    'Assert-XapiCommandSuccess'
)
