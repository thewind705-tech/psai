<#
.SYNOPSIS
Removes psai from your PowerShell module folders.

    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
#>

$documents = [Environment]::GetFolderPath('MyDocuments')
foreach ($modules in @((Join-Path $documents 'WindowsPowerShell\Modules'), (Join-Path $documents 'PowerShell\Modules'))) {
    $folder = Join-Path $modules 'psai'
    if (Test-Path -LiteralPath $folder) {
        Remove-Item -LiteralPath $folder -Recurse -Force
        Write-Host ('Removed ' + $folder) -ForegroundColor Green
    }
}

$settings = Join-Path $HOME '.psai'
if (Test-Path -LiteralPath $settings) {
    $answer = Read-Host ('Also delete your psai settings in ' + $settings + '? [y/N]')
    if ($answer.Trim().ToLowerInvariant().StartsWith('y')) {
        Remove-Item -LiteralPath $settings -Recurse -Force
        Write-Host 'Settings deleted.' -ForegroundColor Green
    } else {
        Write-Host 'Settings kept.'
    }
}
Write-Host 'psai is uninstalled. Close and reopen PowerShell to finish.'
