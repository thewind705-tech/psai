# psai - an AI assistant for PowerShell that runs on your local Ollama or LM Studio models.
# Works on Windows PowerShell 5.1 and PowerShell 7.

$script:PsaiModuleRoot = $PSScriptRoot
$script:PsaiVersion = '0.2.0'

foreach ($psaiPart in @('Json', 'Http', 'Ui', 'Config', 'History', 'Model', 'Chat', 'Agent')) {
    . ([System.IO.Path]::Combine($PSScriptRoot, 'src', $psaiPart + '.ps1'))
}

# Esc / Ctrl+C detection needs a real console window.
$script:PsaiCanReadKeys = $true
try {
    if ([Console]::IsInputRedirected) { $script:PsaiCanReadKeys = $false }
} catch {
    $script:PsaiCanReadKeys = $false
}

function Invoke-Psai {
    <#
    .SYNOPSIS
    psai: an AI assistant for PowerShell that uses your local Ollama or LM Studio models.

    .DESCRIPTION
    psai "what you want to do"   Suggests a PowerShell command, then lets you run or copy it.
    psai                         Starts a chat. Type /exit to leave.
    psai /code [task]            Starts a coding agent in the current folder.
    psai /explain                Explains the last error in this window.
    psai /model                  Picks another model.
    psai /status                 Shows the settings and checks the server.
    psai /config                 Opens the settings file.
    psai /setup                  Runs the first-time setup again.
    psai /history                Lists saved chats.
    psai /resume [number]        Continues a saved chat.
    psai /help                   Shows this list.

    .EXAMPLE
    psai "find the 10 largest files in this folder"

    .EXAMPLE
    psai /code add input validation to the signup form
    #>

    # Remember the user's last error before psai itself does anything.
    $lastUserError = Get-PsaiLastUserError
    $script:PsaiKeyCaptureDepth = 0
    $text = ((@($args) | ForEach-Object { [string]$_ }) -join ' ').Trim()

    try {
        if ($text -eq '') {
            $config = Get-PsaiConfigOrSetup
            if ($config) { Start-PsaiChat -Config $config }
            return
        }

        $lower = $text.ToLowerInvariant()
        if ($lower -eq '--help' -or $lower -eq '-h' -or $lower -eq 'help') {
            Show-PsaiHelp
            return
        }

        if ($text.StartsWith('/', [StringComparison]::Ordinal)) {
            $space = $text.IndexOf(' ')
            if ($space -gt 0) {
                $command = $text.Substring(0, $space).ToLowerInvariant()
                $rest = $text.Substring($space + 1).Trim()
            } else {
                $command = $lower
                $rest = ''
            }
            switch ($command) {
                '/code' {
                    $config = Get-PsaiConfigOrSetup
                    if ($config) { Start-PsaiAgent -Config $config -FirstTask $rest }
                }
                '/setup' {
                    $existing = $null
                    try { $existing = Read-PsaiConfigFile } catch { }
                    [void](Invoke-PsaiSetup -Existing $existing)
                }
                '/config' { Open-PsaiConfigFile }
                '/status' { Show-PsaiStatus }
                '/model' {
                    $config = Get-PsaiConfigOrSetup
                    if ($config) { [void](Update-PsaiModelChoice -Config $config) }
                }
                '/explain' {
                    $config = Get-PsaiConfigOrSetup
                    if ($config) { Invoke-PsaiExplain -Config $config -ErrorRecord $lastUserError }
                }
                '/history' {
                    if ($rest.ToLowerInvariant() -eq 'open') { Open-PsaiChatsFolder } else { Show-PsaiHistory }
                }
                '/resume' {
                    $path = Find-PsaiSavedChat $rest
                    if ($path) {
                        $config = Get-PsaiConfigOrSetup
                        if ($config) {
                            $record = Read-PsaiChat $path
                            if ($record.Mode -eq 'code') {
                                if (-not $record.Root -or -not [System.IO.Directory]::Exists($record.Root)) {
                                    throw ('The project folder of this chat no longer exists: ' + $record.Root)
                                }
                                Set-Location -LiteralPath $record.Root
                                Start-PsaiAgent -Config $config -Resume $record
                            } else {
                                Start-PsaiChat -Config $config -Resume $record
                            }
                        }
                    }
                }
                '/help' { Show-PsaiHelp }
                '/version' { Write-Host ('psai ' + $script:PsaiVersion) }
                default { Write-PsaiError ('Unknown command: ' + $command + '. Type psai /help to see the commands.') }
            }
            return
        }

        $config = Get-PsaiConfigOrSetup
        if ($config) { Invoke-PsaiAsk -Config $config -Request $text -SystemPrompt (Get-PsaiCommandPrompt) }
    } catch {
        Write-PsaiError $_.Exception.Message
    } finally {
        $script:PsaiKeyCaptureDepth = 0
    }
}

Set-Alias -Name psai -Value Invoke-Psai
Export-ModuleMember -Function Invoke-Psai -Alias psai
