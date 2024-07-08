# Ignore SSL certificate validation to avoid errors
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

# Function to prompt user for file paths
function Get-FilePath {
    param (
        [string]$promptMessage
    )
    Write-Host $promptMessage
    return Read-Host
}

# Function to get the list of macros currently on the system
function Get-Macros {
    param (
        [string]$endpointIp,
        [string]$username,
        [string]$password
    )

    Write-Host "Attempting to connect to $endpointIp..."

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
        $response = Invoke-RestMethod -Uri "https://$endpointIp/putxml" -Method 'POST' -Headers $headers -Body $body -SkipCertificateCheck -TimeoutSec 10
        $xmlContent = [xml]$response
        $macros = $xmlContent.Command.MacroGetResult.Macro | ForEach-Object { $_.Name }
        return $macros
    } catch {
        $errorDetails = $_.Exception.Message
        Write-Host "Error fetching macros from: $endpointIp. Response: $errorDetails"
        return @()
    }
}

# Function to prompt user for confirmation
function Get-Confirmation {
    param (
        [string]$promptMessage
    )
    Write-Host $promptMessage " (y/n)"
    $response = Read-Host
    return $response -eq 'y'
}
