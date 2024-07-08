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
$logFile = "RemoveMacros.log"

Display-Message "Option 3 selected: Remove macros"
Log-Message -message "Option 3 selected: Remove macros" -logFile $logFile

# Prompt user for CSV file path
$csvFilePath = Get-FilePath -promptMessage "Please enter the full path to the CSV file:"

# Prompt user for the macros to remove
$macrosToRemove = Read-Host "Please enter the macros to remove (comma separated):"
$macrosToRemoveArray = $macrosToRemove -split ',' | ForEach-Object { $_.Trim() }

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

# Confirm removal
if (-not (Get-Confirmation -promptMessage "Do you want to proceed with the removal?")) {
    Display-Message "Removal cancelled."
    Log-Message -message "Removal cancelled." -logFile $logFile
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
        $message = "Macros on ${endpointIp} ($systemName): $($macros -join ', ')"
        Display-Message $message
        Log-Message -message $message -logFile $logFile
        return $macros
    } catch {
        $errorDetails = $_.Exception.Message
        $message = "Error getting macros from ${endpointIp} ($systemName). Response: $errorDetails"
        Display-Message $message
        Log-Message -message $message -logFile $logFile
        return @()
    }
}

# Function to remove a macro from a system
function Remove-Macro {
    param (
        [string]$endpointIp,
        [string]$username,
        [string]$password,
        [string]$macroName,
        [string]$logFile,
        [string]$systemName
    )

    $message = "Attempting to remove macro $macroName from ${endpointIp} ($systemName)..."
    Display-Message $message
    Log-Message -message $message -logFile $logFile

    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Content-Type", "application/xml")
    $headers.Add("Authorization", "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${username}:${password}")))

    $body = @"
<Command>
    <Macros>
        <Macro>
            <Remove>
                <Name>$macroName</Name>
            </Remove>
        </Macro>
    </Macros>
</Command>
"@

    try {
        $response = Invoke-RestMethod -Uri "https://${endpointIp}/putxml" -Method 'POST' -Headers $headers -Body $body -TimeoutSec 10
        $message = "Macro $macroName removed successfully from ${endpointIp} ($systemName)."
        Display-Message $message
        Log-Message -message $message -logFile $logFile
        return $true
    } catch {
        $errorDetails = $_.Exception.Message
        $message = "Error removing macro $macroName from ${endpointIp} ($systemName). Response: $errorDetails"
        Display-Message $message
        Log-Message -message $message -logFile $logFile
        return $false
    }
}

# Perform the removal
$removalSummary = @()

foreach ($system in $systems) {
    $systemName = $system.'system name'
    $ipAddress = $system.'ip address'
    $username = $system.'username'
    $password = $system.'password'

    $macros = Get-Macros -endpointIp $ipAddress -username $username -password $password -logFile $logFile -systemName $systemName

    $systemSummary = [PSCustomObject]@{
        IPAddress = $ipAddress
        SystemName = $systemName
        TotalMacros = $macrosToRemoveArray.Count
        SuccessfulRemovals = 0
        FailedRemovals = 0
    }

    foreach ($macro in $macrosToRemoveArray) {
        if ($macros -contains $macro) {
            $success = Remove-Macro -endpointIp $ipAddress -username $username -password $password -macroName $macro -logFile $logFile -systemName $systemName
            if ($success) {
                $systemSummary.SuccessfulRemovals++
            } else {
                $systemSummary.FailedRemovals++
            }
        } else {
            $message = "Macro $macro not found on ${ipAddress} ($systemName)."
            Display-Message $message
            Log-Message -message $message -logFile $logFile
            $systemSummary.FailedRemovals++
        }
    }

    $removalSummary += $systemSummary
}

# Generate summary
$successfulSystems = $removalSummary | Where-Object { $_.SuccessfulRemovals -eq $_.TotalMacros }
$partialSystems = $removalSummary | Where-Object { $_.SuccessfulRemovals -gt 0 -and $_.SuccessfulRemovals -lt $_.TotalMacros }
$failedSystems = $removalSummary | Where-Object { $_.SuccessfulRemovals -eq 0 }

Display-Message "Removal completed."
Log-Message -message "Removal completed." -logFile $logFile

if ($successfulSystems.Count -gt 0) {
    $message = "Successfully removed all specified macros from $($successfulSystems.Count) systems."
    Display-Message $message
    Log-Message -message $message -logFile $logFile
}

if ($partialSystems.Count -gt 0) {
    $message = "Partially removed some macros from $($partialSystems.Count) systems."
    Display-Message $message
    Log-Message -message $message -logFile $logFile
}

if ($failedSystems.Count -gt 0) {
    $message = "$($failedSystems.Count) systems were unsuccessful for removing any macros."
    Display-Message $message
    Log-Message -message $message -logFile $logFile
}
