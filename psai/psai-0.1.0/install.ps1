<#
.SYNOPSIS
Installs psai for your Windows user account.

.DESCRIPTION
Copies the psai module into your PowerShell module folders (for Windows PowerShell 5.1
and PowerShell 7), unblocks the files, and, if PowerShell blocks scripts, offers to allow
local scripts for your user.

Run it from the folder you unzipped:
    powershell -ExecutionPolicy Bypass -File .\install.ps1
#>

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'psai'
if (-not (Test-Path -LiteralPath (Join-Path $source 'psai.psd1'))) {
    Write-Host 'The psai folder was not found next to install.ps1. Unzip the whole download and try again.' -ForegroundColor Red
    exit 1
}

$documents = [Environment]::GetFolderPath('MyDocuments')
if (-not $documents) {
    Write-Host 'Could not find your Documents folder.' -ForegroundColor Red
    exit 1
}
$moduleFolders = @(
    (Join-Path $documents 'WindowsPowerShell\Modules'),
    (Join-Path $documents 'PowerShell\Modules')
)

Write-Host ''
foreach ($modules in $moduleFolders) {
    $destination = Join-Path $modules 'psai'
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
    try { Get-ChildItem -LiteralPath $destination -Recurse -File | Unblock-File } catch { }
    Write-Host ('Installed to ' + $destination) -ForegroundColor Green
}

# PowerShell blocks all scripts by default on Windows. Check the setting that applies
# to normal windows (ignoring the -ExecutionPolicy Bypass used to run this installer).
$policy = 'Restricted'
$policyScope = 'Default'
foreach ($scope in @('MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine')) {
    $value = [string](Get-ExecutionPolicy -Scope $scope)
    if ($value -ne 'Undefined') {
        $policy = $value
        $policyScope = $scope
        break
    }
}

if (@('Restricted', 'AllSigned') -contains $policy) {
    Write-Host ''
    Write-Host ('PowerShell is set to block scripts (' + $policy + '), so psai cannot load yet.') -ForegroundColor Yellow
    if (@('MachinePolicy', 'UserPolicy') -contains $policyScope) {
        Write-Host 'This setting comes from your organization (Group Policy), so it cannot be changed here.' -ForegroundColor Yellow
        Write-Host 'Ask your IT team to allow the RemoteSigned execution policy.'
    } else {
        Write-Host 'psai needs the "RemoteSigned" setting for your user account: scripts on your computer can run,'
        Write-Host 'and scripts downloaded from the internet must be unblocked first.'
        $answer = Read-Host 'Change it now? [Y/n]'
        if ($answer -eq '' -or $answer.Trim().ToLowerInvariant().StartsWith('y')) {
            # Because this installer runs with "-ExecutionPolicy Bypass", PowerShell reports a
            # "Security error" even when the change worked, so check the result instead.
            $problem = ''
            try {
                Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
            } catch {
                $problem = $_.Exception.Message
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $problem = $_.ErrorDetails.Message }
            }
            if ([string](Get-ExecutionPolicy -Scope CurrentUser) -eq 'RemoteSigned') {
                Write-Host 'Done: your execution policy is now RemoteSigned.' -ForegroundColor Green
            } else {
                Write-Host ('Could not change it: ' + $problem) -ForegroundColor Red
                Write-Host 'Open PowerShell normally and run:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
            }
        } else {
            Write-Host 'Skipped. You can do it later with:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
        }
    }
}

Write-Host ''
Write-Host 'psai is installed. Open a new PowerShell window and type:  psai' -ForegroundColor Cyan
Write-Host 'The first run asks whether you use Ollama or LM Studio.'
Write-Host ''
