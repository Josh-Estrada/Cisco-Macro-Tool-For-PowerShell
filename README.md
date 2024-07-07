## Cisco Macro Tool For PowerShell
The Cisco Macro Tool For PowerShell is a script-based tool designed to manage macros on Cisco systems using only built-in PowerShell cmdlets. The tool offers 3 primary functions and 2 secondary functions. The primary functions are uploading Pexip OTJ macros, uploading .js macros, and removing macros. The secondary functions are the ability to check all macros on a single system or all macros on all systems. Each function generates logs to help you keep track of operations and any issues that may arise.

## Note: This is not an official Pexip or Cisco Tool. This is a community tool.

## Features
- Upload Pexip OTJ macros: Upload and manage Pexip OTJ macros from ZIP files.
- Upload .js macros: Upload and manage JavaScript macros from .js files.
- Remove macros: Remove specified macros from Cisco systems.
- Check macros on a specific system: Verify the macros currently installed on a single system.
- Check macros on all systems: Verify the macros currently installed across all systems.

## Prerequisites
- PowerShell Core (pwsh) installed on your machine.
- Windows only. MacOS not supported at this time.
- Cisco systems with administrative access.
- Direct network connectivity to the Cisco systems over port 443
- CSV file with the following headers: system name, ip address, username, password.
- A CSV template is provided in the repository.
- Macro files in .js format or Pexip OTJ macros in a ZIP directory.

## Installation
- Clone the repository:
- git clone https://github.com/Josh-Estrada/Cisco-Macro-Tool-For-PowerShell.git
- The repo consists of mutliple ps1 scripts that perform the various fucntions, but you only need to run the MainMenu.ps1
- Change directory to where you downloaded the repo. cd Cisco-Macro-Tool-For-PowerShell

## Usage
Run the MainMenu.ps1 script to launch the tool.:

pwsh ./MainMenu.ps1
You will be presented with a menu to choose from:

Choose an option:
1. Upload Pexip OTJ macros
2. Upload .js macros
3. Remove macros
4. Check macros on specific system
5. Check macros on all systems
6. Exit
Enter your choice (1, 2, 3, 4, 5, 6):

## Detailed Steps
## 1. Upload Pexip OTJ macros
Enter the path to your CSV file and the directory containing the Pexip OTJ ZIP files. Review the number of matching and non-matching systems, and confirm to proceed with the upload.

## How It Works:
- Provide the full path of the completed CSV.
- Ensure the CSV includes the System Name, IP Address, Username, and Password. Spaces in system names are allowed.
- Provide the directory where OTJ ZIP files exist. No other files or subdirectories should be in the main directory.
- The OTJ ZIP files should follow the naming convention systemname-otj-macro-latest.zip. The system name in the CSV must match the system name in the ZIP file.
- Confirm the upload.
- The tool iterates through the CSV and, for any matching ZIP files, extracts to a temporary folder and uploads the corresponding macros to the corresponding 
  systems.
- Log File: UploadPexipOTJMacros.log


## 2. Upload .js macros
Enter the path to your CSV file and the directory containing the .js files. Review the number of .js files found and the number of systems in the CSV file, and confirm to proceed with the upload.

## How It Works:
- Provide the full path of the completed CSV.
- Provide the directory where .js files exist. Ensure no non-.js files or subdirectories are present.
- Confirm the upload.
- The tool iterates through the CSV and uploads all macros to all systems.
- Log File: UploadJsMacros.log


## 3. Remove macros
Enter the path to your CSV file and specify the macros to remove (comma-separated). Review the number of systems found in the CSV file, and confirm to proceed with the removal.

## How It Works:

- Provide the full path of the completed CSV.
- Specify the macro names to be removed. The macro name must match exactly as it appears on the systems. Multiple macros can be provided by using commas.
- Confirm the removal.
- The tool iterates through the CSV and removes all specified macros from all systems.
- Log File: RemoveMacros.log


## 4. Check macros on a specific system
Enter the IP address or hostname of the specific system to check. The tool will display the list of installed macros on that system.

## How It Works:

- Enter the system's IP address or hostname.
- The tool retrieves and displays the list of macros installed on the specified system.
- Log File: CheckMacrosOnSystem.log


## 5. Check macros on all systems
Enter the path to your CSV file. The tool will display the list of installed macros on all systems in the CSV.

## How It Works:

- Provide the full path of the completed CSV.
- The tool iterates through the CSV and retrieves the list of macros installed on each system.
- Log File: CheckMacrosOnAllSystems.log
- Logging
- Each function generates a log file in the same directory as the script. The log files contain detailed information about the operations performed, including 
  successful and failed attempts.

## 6. Exit
Exits the Main script and macro tool.

## Logging
- UploadPexipOTJMacros.log: Logs for uploading Pexip OTJ macros.
- UploadJsMacros.log: Logs for uploading .js macros.
- RemoveMacros.log: Logs for removing macros.
- CheckMacrosOnSystem.log: Logs for checking macros on a specific system.
- CheckMacrosOnAllSystems.log: Logs for checking macros on all systems.

## Contributing
Feel free to submit issues and pull requests to improve the tool.
