# Source helper functions
. .\HelperFunctions.ps1

# Function to log messages to a file
function Log-Message {
    param (
        [string]$message,
        [string]$logFile
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp - $message"
    Add-Content -Path $logFile -Value $logEntry
}

# Function to display messages in the console
function Display-Message {
    param (
        [string]$message
    )
    Write-Host $message
}

# Initialize log file
$logFile = "CheckMacrosOnAllSystems.log"

Display-Message "Option 5 selected: Check macros on all systems"
Log-Message -message "Option 5 selected: Check macros on all systems" -logFile $logFile

# Prompt user for CSV file path
$csvFilePath = Get-FilePath -promptMessage "Please enter the full path to the CSV file:"

# Import CSV
try {
    $systems = @(Import-Csv -Path $csvFilePath)
    if ($systems -eq $null -or $systems.Count -eq 0) {
        throw "CSV file is empty or improperly formatted."
    }
    Display-Message "Found $($systems.Count) systems in the CSV file."
    Log-Message -message "Found $($systems.Count) systems in the CSV file." -logFile $logFile
} catch {
    $errorDetails = $_.Exception.Message
    Display-Message "Error importing CSV file. Response: $errorDetails"
    Log-Message -message "Error importing CSV file. Response: $errorDetails" -logFile $logFile
    return
}

# Confirm check
if (-not (Get-Confirmation -promptMessage "Do you want to proceed with checking macros on all systems?")) {
    Display-Message "Check cancelled."
    Log-Message -message "Check cancelled." -logFile $logFile
    return
}

# Bypass SSL certificate validation
Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

# Function to get macros from a system
function Get-Macros {
    param (
        [string]$endpointIp,
        [string]$username,
        [string]$password,
        [string]$logFile,
        [string]$systemName
    )

    $message = "Attempting to get macros from $endpointIp ($systemName)..."
    Display-Message $message
    Log-Message -message $message -logFile $logFile

    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Content-Type", "application/xml")
    $headers.Add("Authorization", "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${username}:${password}")))

    $body = @"
<Command>
    <Macros>
        <Macro>
            <Get/>
        </Macro>
    </Macros>
</Command>
"@

    try {
        $response = Invoke-RestMethod -Uri "https://${endpointIp}/putxml" -Method 'POST' -Headers $headers -Body $body -TimeoutSec 10
        [xml]$xmlResponse = $response
        $macros = $xmlResponse.Command.MacroGetResult.Macro | ForEach-Object { $_.Name }
        if ($macros.Count -gt 0) {
            $message = "The following macros were found on ${endpointIp} ($systemName): $($macros -join ', ')"
        } else {
            $message = "No macros found on ${endpointIp} ($systemName)."
        }
        Display-Message $message
        Log-Message -message $message -logFile $logFile
    } catch {
        $errorDetails = $_.Exception.Message
        $message = "Error getting macros from ${endpointIp} ($systemName). Response: $errorDetails"
        Display-Message $message
        Log-Message -message $message -logFile $logFile
    }
}

# Perform the check
foreach ($system in $systems) {
    $systemName = $system.'system name'
    $ipAddress = $system.'ip address'
    $username = $system.'username'
    $password = $system.'password'

    Get-Macros -endpointIp $ipAddress -username $username -password $password -logFile $logFile -systemName $systemName
}
