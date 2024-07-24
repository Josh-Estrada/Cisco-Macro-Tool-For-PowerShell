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
$logFile = "RemoveUIExtensions.log"

Display-Message "Option 6 selected: Remove UI extensions"
Log-Message -message "Option 6 selected: Remove UI extensions" -logFile $logFile

# Prompt user for CSV file path
$csvFilePath = Get-FilePath -promptMessage "Please enter the full path to the CSV file:"

# Prompt user for the UI IDs to remove
$uiIdsToRemove = Read-Host "Please enter the UI IDs to remove (comma separated):"
$uiIdsToRemoveArray = $uiIdsToRemove -split ',' | ForEach-Object { $_.Trim() }

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

# Function to remove a UI extension from a system
function Remove-UIExtension {
    param (
        [string]$endpointIp,
        [string]$username,
        [string]$password,
        [string]$uiId,
        [string]$logFile,
        [string]$systemName
    )

    $message = "Attempting to remove UI extension $uiId from ${endpointIp} ($systemName)..."
    Display-Message $message
    Log-Message -message $message -logFile $logFile

    $headers = @{
        "Content-Type"  = "application/xml"
        "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${username}:${password}"))
    }

    $body = @"
<Command>
    <UserInterface>
        <Extensions>
            <Panel>
                <Remove>
                    <PanelId>$uiId</PanelId>
                </Remove>
            </Panel>
        </Extensions>
    </UserInterface>
</Command>
"@

    try {
        $response = Invoke-RestMethod -Uri "https://${endpointIp}/putxml" -Method 'POST' -Headers $headers -Body $body -TimeoutSec 10
        $message = "UI extension $uiId removed successfully from ${endpointIp} ($systemName)."
        Display-Message $message
        Log-Message -message $message -logFile $logFile
        return $true
    } catch {
        $errorDetails = $_.Exception.Message
        $message = "Error removing UI extension $uiId from ${endpointIp} ($systemName). Response: $errorDetails"
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

    $systemSummary = [PSCustomObject]@{
        IPAddress = $ipAddress
        SystemName = $systemName
        TotalUIExtensions = $uiIdsToRemoveArray.Count
        SuccessfulRemovals = 0
        FailedRemovals = 0
    }

    foreach ($uiId in $uiIdsToRemoveArray) {
        $success = Remove-UIExtension -endpointIp $ipAddress -username $username -password $password -uiId $uiId -logFile $logFile -systemName $systemName
        if ($success) {
            $systemSummary.SuccessfulRemovals++
        } else {
            $systemSummary.FailedRemovals++
        }
    }

    $removalSummary += $systemSummary
}

# Generate summary
$successfulSystems = $removalSummary | Where-Object { $_.SuccessfulRemovals -eq $_.TotalUIExtensions }
$partialSystems = $removalSummary | Where-Object { $_.SuccessfulRemovals -gt 0 -and $_.SuccessfulRemovals -lt $_.TotalUIExtensions }
$failedSystems = $removalSummary | Where-Object { $_.SuccessfulRemovals -eq 0 }

Display-Message "Removal completed."
Log-Message -message "Removal completed." -logFile $logFile

if ($successfulSystems.Count -gt 0) {
    $message = "Successfully removed all specified UI extensions from $($successfulSystems.Count) systems."
    Display-Message $message
    Log-Message -message $message -logFile $logFile
}

if ($partialSystems.Count -gt 0) {
    $message = "Partially removed some UI extensions from $($partialSystems.Count) systems."
    Display-Message $message
    Log-Message -message $message -logFile $logFile
}

if ($failedSystems.Count -gt 0) {
    $message = "$($failedSystems.Count) systems were unsuccessful for removing any UI extensions."
    Display-Message $message
    Log-Message -message $message -logFile $logFile
}
