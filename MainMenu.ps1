# Main script execution
while ($true) {
    Write-Host ""
    Write-Host "Welcome to the Cisco Macro Tool"
    Write-Host "Please choose an option to get started:"
    Write-Host "1. Upload Pexip OTJ macros"
    Write-Host "2. Upload .js macros"
    Write-Host "3. Remove macros"
    Write-Host "4. Check macros on a specific system"
    Write-Host "5. Check macros on all systems"
    Write-Host "6. Remove UI extensions"
    Write-Host "7. Exit"
    $option = Read-Host "Enter your choice (1, 2, 3, 4, 5, 6, or 7)"

    switch ($option) {
        "1" {
            . .\UploadPexipOTJMacros.ps1
        }
        "2" {
            . .\UploadJsMacros.ps1
        }
        "3" {
            . .\RemoveMacros.ps1
        }
        "4" {
            . .\CheckMacrosOnSystem.ps1
        }
        "5" {
            . .\CheckMacrosOnAllSystems.ps1
        }
        "6" {
            . .\RemoveUIExtensions.ps1
        }
        "7" {
            Write-Host "Exiting..."
            exit
        }
        default {
            Write-Host "Invalid option selected. Please choose a valid option."
        }
    }
}
