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
$logFile = "UploadPexipOTJMacros.log"

Display-Message "Option 1 selected: Upload Pexip OTJ macros"
Log-Message -message "Option 1 selected: Upload Pexip OTJ macros" -logFile $logFile

# Prompt user for CSV file path
$csvFilePath = Get-FilePath -promptMessage "Please enter the full path to the CSV file:"

# Prompt user for the directory containing ZIP files
$zipDirectory = Get-FilePath -promptMessage "Please enter the full path to the directory containing the Pexip OTJ ZIP files:"

# List ZIP files
$zipFiles = Get-ChildItem -Path $zipDirectory -Filter *-otj-macro-latest*.zip

# Import CSV
$systems = Import-Csv -Path $csvFilePath

# Check for matching systems
$matchingSystems = @()
$nonMatchingSystems = 0

foreach ($system in $systems) {
    $systemName = $system.'system name'.Replace(" ", "")
    $matchingZipFiles = $zipFiles | Where-Object { $_.Name -like "*$($systemName.ToLower())*-otj-macro-latest*.zip" }
    if ($matchingZipFiles.Count -gt 0) {
        $matchingSystems += [PSCustomObject]@{ SystemName = $system.'system name'; IPAddress = $system.'ip address'; Username = $system.'username'; Password = $system.'password'; ZipFile = $matchingZipFiles }
    } else {
        $nonMatchingSystems++
    }
}

Display-Message "Found $($matchingSystems.Count) systems with matching Pexip OTJ ZIP files."
Display-Message "Found $nonMatchingSystems systems with no matching Pexip OTJ ZIP files."
Log-Message -message "Found $($matchingSystems.Count) systems with matching Pexip OTJ ZIP files." -logFile $logFile
Log-Message -message "Found $nonMatchingSystems systems with no matching Pexip OTJ ZIP files." -logFile $logFile

# Confirm upload
if (-not (Get-Confirmation -promptMessage "Do you want to proceed with the upload?")) {
    Display-Message "Upload cancelled."
    Log-Message -message "Upload cancelled." -logFile $logFile
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

# Function to upload macros from a ZIP file
function Upload-MacroFromZip {
    param (
        [string]$endpointIp,
        [string]$username,
        [string]$password,
        [string]$zipFilePath,
        [string]$logFile,
        [string]$systemName
    )

    $message = "Attempting to upload macros from $zipFilePath to $endpointIp ($systemName)..."
    Display-Message $message
    Log-Message -message $message -logFile $logFile

    $tempDir = Join-Path -Path $env:TEMP -ChildPath ([System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetRandomFileName()))
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    try {
        Expand-Archive -Path $zipFilePath -DestinationPath $tempDir -Force
        $jsFiles = Get-ChildItem -Path $tempDir -Filter *.js

        foreach ($jsFile in $jsFiles) {
            $macroName = [System.IO.Path]::GetFileNameWithoutExtension($jsFile.Name)
            $jsCode = Get-Content -Path $jsFile.FullName -Raw

            $headers = @{
                "Content-Type"  = "application/xml"
                "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${username}:${password}"))
            }

            $encodedJsCode = [System.Security.SecurityElement]::Escape($jsCode)

            $body = @"
<Command>
    <Macros>
        <Macro>
            <Save command="True">
                <name>$macroName</name>
                <body>$encodedJsCode</body>
                <overWrite>True</overWrite>
                <Transpile>False</Transpile>
            </Save>
        </Macro>
    </Macros>
</Command>
"@

            try {
                $response = Invoke-RestMethod -Uri "https://$endpointIp/putxml" -Method 'POST' -Headers $headers -Body $body -TimeoutSec 10
                $message = "Macro $macroName uploaded successfully to $endpointIp ($systemName) from $zipFilePath."
                Display-Message $message
                Log-Message -message $message -logFile $logFile
                
                # Enable the uploaded macro
                Enable-Macro -endpointIp $endpointIp -username $username -password $password -macroName $macroName -logFile $logFile -systemName $systemName
                
            } catch {
                $errorDetails = $_.Exception.Message
                $message = "Error uploading macro $macroName to: $endpointIp ($systemName) from $zipFilePath. Response: $errorDetails"
                Display-Message $message
                Log-Message -message $message -logFile $logFile
            }
        }

    } catch {
        $message = "Error unzipping file $zipFilePath"
        Display-Message $message
        Log-Message -message $message -logFile $logFile
    } finally {
        Remove-Item -Recurse -Force -Path $tempDir
    }
}

# Function to enable a macro on a system
function Enable-Macro {
    param (
        [string]$endpointIp,
        [string]$username,
        [string]$password,
        [string]$macroName,
        [string]$logFile,
        [string]$systemName
    )

    $message = "Attempting to enable macro $macroName on $endpointIp ($systemName)..."
    Display-Message $message
    Log-Message -message $message -logFile $logFile

    $headers = @{
        "Content-Type"  = "application/xml"
        "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${username}:${password}"))
    }

    $body = @"
<Command>
    <Macros>
        <Macro>
            <Activate>
                <name>$macroName</name>
            </Activate>
        </Macro>
    </Macros>
</Command>
"@

    try {
        $response = Invoke-RestMethod -Uri "https://$endpointIp/putxml" -Method 'POST' -Headers $headers -Body $body -TimeoutSec 10
        $message = "Macro $macroName enabled successfully on $endpointIp ($systemName)."
        Display-Message $message
        Log-Message -message $message -logFile $logFile
    } catch {
        $errorDetails = $_.Exception.Message
        $message = "Error enabling macro $macroName on $endpointIp ($systemName). Response: $errorDetails"
        Display-Message $message
        Log-Message -message $message -logFile $logFile
    }
}

# Function to restart macro runtime
function Restart-MacroRuntime {
    param (
        [string]$endpointIp,
        [string]$username,
        [string]$password,
        [string]$logFile,
        [string]$systemName
    )

    $message = "Attempting to restart macro runtime on $endpointIp ($systemName)..."
    Display-Message $message
    Log-Message -message $message -logFile $logFile

    $headers = @{
        "Content-Type"  = "application/xml"
        "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${username}:${password}"))
    }

    $body = @"
<Command>
    <Macros>
        <Runtime>
            <Restart command="True"/>
        </Runtime>
    </Macros>
</Command>
"@

    try {
        $response = Invoke-RestMethod -Uri "https://$endpointIp/putxml" -Method 'POST' -Headers $headers -Body $body -TimeoutSec 10
        $message = "Macro runtime restarted successfully on $endpointIp ($systemName)."
        Display-Message $message
        Log-Message -message $message -logFile $logFile
    } catch {
        $errorDetails = $_.Exception.Message
        $message = "Error restarting macro runtime on $endpointIp ($systemName). Response: $errorDetails"
        Display-Message $message
        Log-Message -message $message -logFile $logFile
    }
}

# Perform the upload and restart macro runtimes
$uploadedSystems = 0

foreach ($system in $matchingSystems) {
    foreach ($zipFile in $system.ZipFile) {
        Upload-MacroFromZip -endpointIp $system.IPAddress -username $system.Username -password $system.Password -zipFilePath $zipFile.FullName -logFile $logFile -systemName $system.SystemName
        Restart-MacroRuntime -endpointIp $system.IPAddress -username $system.Username -password $system.Password -logFile $logFile -systemName $system.SystemName
        $uploadedSystems++
    }
}

$message = "Upload completed. Successfully uploaded macros to $uploadedSystems systems."
Display-Message $message
Log-Message -message $message -logFile $logFile
