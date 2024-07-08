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
$logFile = "CheckMacrosOnSystem.log"

Display-Message "Option 4 selected: Check macros on a specific system"
Log-Message -message "Option 4 selected: Check macros on a specific system" -logFile $logFile

# Prompt user for system details
$endpointIp = Read-Host "Please enter the IP address of the system"
$username = Read-Host "Please enter the username"
$password = Read-Host "Please enter the password" -AsSecureString
$passwordPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))

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

# Function to get macros from a single system
function Get-Macros {
    param (
        [string]$endpointIp,
        [string]$username,
        [string]$password,
        [string]$logFile
    )

    $message = "Attempting to get macros from $endpointIp..."
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
            $message = "The following macros were found on ${endpointIp}: $($macros -join ', ')"
        } else {
            $message = "No macros found on ${endpointIp}."
        }
        Display-Message $message
        Log-Message -message $message -logFile $logFile
    } catch {
        $errorDetails = $_.Exception.Message
        $message = "Error getting macros from ${endpointIp}. Response: $errorDetails"
        Display-Message $message
        Log-Message -message $message -logFile $logFile
    }
}

# Perform the check
Get-Macros -endpointIp $endpointIp -username $username -password $passwordPlain -logFile $logFile
