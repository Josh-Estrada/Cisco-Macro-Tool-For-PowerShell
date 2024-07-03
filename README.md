## Cisco Macro Tool PowerShell
The Cisco Macro Tool PowerShell is a script-based tool designed to manage macros on Cisco systems. The tool offers three primary functions: uploading Pexip OTJ macros, uploading .js macros, and removing macros. Each function generates logs to help you keep track of operations and any issues that may arise.

## Features
- Upload Pexip OTJ macros: Upload and manage Pexip OTJ macros from ZIP files.
- Upload .js macros: Upload and manage JavaScript macros from .js files.
- Remove macros: Remove specified macros from Cisco systems.

## Prerequisites
- PowerShell Core (pwsh) installed on your machine.
- Cisco systems with administrative access.
- CSV file with the following headers: system name, ip address, username, password.
- A CSV template is provided in the repository.


## Installation
Clone the repository:

git clone https://github.com/JOsh-Estrada/Cisco-Macro-Tool-PowerShell.git

cd Cisco-Macro-Tool-PowerShell

## Usage
Run the main script to access the three primary functions:

pwsh ./MainMenu.ps1 You will be presented with a menu to choose from:

Choose an option:

Upload Pexip OTJ macros
Upload .js macros
Remove macros
Exit Enter your choice (1, 2, 3, or 4):

## Detailed Steps
Once the tool starts up, choose from the three separate options.

## 1. Upload Pexip OTJ macros
Enter the path to your CSV file. Enter the path to the directory containing the Pexip OTJ ZIP files. Review the number of matching and non-matching systems. Confirm to proceed with the upload.

How It Works

- Provide the full path of the completed CSV.
- System Name is required in CSV, but spaces are allowed.
- Provide the directory where OTJ ZIP files exist. No other files or subdirectories should exist in the main directory.
- Confirm the upload.
- The tool will iterate through the CSV and for any matching ZIP files, it will extract to a temp folder and then upload the corresponding macros to the corresponding systems.
- Log File: UploadPexipOTJMacros.log

## 2. Upload .js macros
Enter the path to your CSV file. Enter the path to the directory containing the .js files. Review the number of .js files found and the number of systems in the CSV file. Confirm to proceed with the upload.

How It Works

- Provide the full path of the completed CSV.
- Provide the directory where .js files exist. Ensure no non-js files or other subdirectories are present.
- Confirm the upload.
- The tool will iterate through the CSV and upload all macros to all systems.
- Log File: UploadJsMacros.log

## 3. Remove macros
Enter the path to your CSV file. Specify the macros to remove (comma-separated). Review the number of systems found in the CSV file. Confirm to proceed with the removal.

How It Works

- Provide the full path of the completed CSV.
- Specify the macro names to be removed. The macro name must match exactly as it appears on the systems. Multiple macros can be provided by using a comma.
- Confirm the removal.
- The tool will iterate through the CSV and remove all specified macros from all systems.
- Log File: RemoveMacros.log

## Logging
Each function generates a log file in the same directory as the script. The log files contain detailed information about the operations performed, including successful and failed attempts.

UploadPexipOTJMacros.log: Logs for uploading Pexip OTJ macros. UploadJsMacros.log: Logs for uploading .js macros. RemoveMacros.log: Logs for removing macros.

## Contributing
Feel free to submit issues and pull requests to improve the tool.
