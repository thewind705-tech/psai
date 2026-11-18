# One-shot commands ("psai <request>"), chat mode ("psai") and error explanations.

$script:PsaiOsName = $null

function Get-PsaiShellName {
    $v = $PSVersionTable.PSVersion
    if ($PSVersionTable.PSEdition -eq 'Core') { return ('PowerShell ' + $v.Major + '.' + $v.Minor) }
    return ('Windows PowerShell ' + $v.Major + '.' + $v.Minor)
}

# Extra rules for the model, for things that only work in newer PowerShell versions.
function Get-PsaiShellLimits {
    if ($PSVersionTable.PSEdition -eq 'Core') { return '' }
    return ' Windows PowerShell 5.1 has no &&, || , ternary (a ? b : c) or ?? operators, and no ForEach-Object -Parallel.'
}

function Get-PsaiOsName {
    if ($script:PsaiOsName) { return $script:PsaiOsName }
    $name = ''
    if ($env:OS -eq 'Windows_NT') {
        try {
            $info = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            $name = [string]$info.ProductName
            $build = 0
            [void][int]::TryParse([string]$info.CurrentBuildNumber, [ref]$build)
            # Windows 11 still reports "Windows 10" in ProductName.
            if ($build -ge 22000) { $name = $name.Replace('Windows 10', 'Windows 11') }
        } catch { }
    }
    if (-not $name) { $name = [System.Environment]::OSVersion.VersionString }
    $script:PsaiOsName = $name
    return $name
}

function Get-PsaiCommandPrompt {
    $shell = Get-PsaiShellName
    $lines = @(
        ('You are psai, a command-line helper in ' + $shell + ' on ' + (Get-PsaiOsName) + '.'),
        ('Current folder: ' + (Get-Location).Path),
        '',
        'The user describes something they want to do on their computer.',
        'Reply with ONE PowerShell command (or a short script) that does it, in a single ```powershell code block,',
        'then one short sentence that says what it does.',
        '',
        'Rules:',
        ('- The command must work in ' + $shell + '.' + (Get-PsaiShellLimits)),
        '- Use full cmdlet and parameter names, not aliases.',
        '- If the user has to fill something in (a path, a name), use an obvious placeholder and say so.',
        '- If the request is a question and not a task, answer it in 1 to 3 sentences without a code block.',
        '- Reply in the language the user writes in. The command itself stays PowerShell.'
    )
    return (($lines -join "`n") + (Get-PsaiCustomPrompt 'command'))
}

function Get-PsaiChatPrompt {
    $shell = Get-PsaiShellName
    $lines = @(
        ('You are psai, a helpful assistant in the user''s terminal (' + $shell + ' on ' + (Get-PsaiOsName) + ').'),
        ('Today is ' + (Get-Date).ToString('yyyy-MM-dd') + '. The current folder is ' + (Get-Location).Path + '.'),
        'Answer clearly and keep it short unless the user asks for detail.',
        'The terminal shows plain text: do not use Markdown headings or tables. Use short paragraphs, simple "-" lists and ``` code blocks for code.',
        ('When the user asks how to do something on their computer, prefer PowerShell commands that work in ' + $shell + '.' + (Get-PsaiShellLimits)),
        'Reply in the language the user writes in.'
    )
    return (($lines -join "`n") + (Get-PsaiCustomPrompt 'chat'))
}

function Get-PsaiExplainPrompt {
    $shell = Get-PsaiShellName
    $lines = @(
        ('You are psai, a helper in ' + $shell + ' on ' + (Get-PsaiOsName) + '.'),
        'The user shows you an error from their PowerShell window.',
        'Explain in 2 to 4 short sentences, in plain words, what went wrong and how to fix it.',
        ('If a corrected command would help, give it in one ```powershell code block at the end. It must work in ' + $shell + '.' + (Get-PsaiShellLimits)),
        'Reply in the same language as the error message.'
    )
    return (($lines -join "`n") + (Get-PsaiCustomPrompt 'explain'))
}

# Returns the code inside the first ``` block of the text, or $null.
function Get-PsaiCodeBlock {
    param([string]$Text)
    if (-not $Text) { return $null }
    $match = [regex]::Match($Text, '(?s)```[ \t]*[\w+-]*[ \t]*\r?\n(.*?)\r?\n[ \t]*```')
    if (-not $match.Success) {
        # A block written on one line: ```powershell Get-Date```
        $match = [regex]::Match($Text, '(?s)```(?:(?:powershell|pwsh|ps1|ps)[ \t]+)?(.*?)```', [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')
    }
    if (-not $match.Success) { return $null }
    $code = $match.Groups[1].Value.Trim()
    if ($code.Length -eq 0) { return $null }
    return $code
}

# Puts a command into the PowerShell history so the Up arrow brings it back.
function Add-PsaiReadLineHistory {
    param([string]$Line)
    try {
        [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($Line)
        return $true
    } catch {
        return $false
    }
}

# Sends one request (no conversation) and offers to run or copy the suggested command.
function Invoke-PsaiAsk {
    param($Config, [string]$Request, [string]$SystemPrompt)
    $messages = New-Object System.Collections.Generic.List[object]
    $messages.Add(@{ role = 'system'; content = $SystemPrompt })
    $messages.Add(@{ role = 'user'; content = $Request })
    Write-Host ''
    $res = Invoke-PsaiModel -Config $Config -Messages $messages
    if ($res.cancelled) {
        Write-PsaiNote '(stopped)'
        return
    }
    if (-not $res.content) {
        Write-PsaiNote '(the model gave an empty answer; try asking again in other words)'
        return
    }
    $code = Get-PsaiCodeBlock $res.content
    if (-not $code) { return }

    Write-Host ''
    if (Test-PsaiRisky $code) {
        Write-Host '  Careful: this command can delete or change things. Read it before you run it.' -ForegroundColor Red
    }
    $choice = Read-PsaiChoice '  Run it? [y] yes  [c] copy  [n] no: ' @('y', 'c', 'n') 'n'
    if ($choice -eq 'n') { return }
    $inHistory = Add-PsaiReadLineHistory $code
    if ($choice -eq 'c') {
        try {
            Set-Clipboard -Value $code
            $note = 'Copied.'
            if ($inHistory) { $note = $note + ' It is also in your history: press the Up arrow to edit it.' }
            Write-PsaiNote $note
        } catch {
            Write-PsaiError ("Couldn't copy: " + $_.Exception.Message)
        }
        return
    }
    Write-Host ''
    try {
        Invoke-Expression $code | Out-Host
    } catch {
        Write-PsaiError $_.Exception.Message
    }
}

# Finds the newest error in this PowerShell window that did not come from psai itself.
function Get-PsaiLastUserError {
    $root = $script:PsaiModuleRoot
    $errors = @($global:Error)
    foreach ($e in $errors) {
        if ($null -eq $e) { continue }
        $where = ''
        if ($e -is [System.Management.Automation.ErrorRecord]) {
            $where = [string]$e.ScriptStackTrace
            if ($e.InvocationInfo) { $where = $where + ' ' + [string]$e.InvocationInfo.ScriptName }
        }
        if ($root -and $where.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
        return $e
    }
    return $null
}

function Invoke-PsaiExplain {
    param($Config, $ErrorRecord)
    if ($null -eq $ErrorRecord) {
        Write-PsaiNote 'There is no recent error in this PowerShell window.'
        return
    }
    $text = ''
    try { $text = ($ErrorRecord | Out-String).Trim() } catch { $text = [string]$ErrorRecord }
    if ($text.Length -gt 3000) { $text = $text.Substring(0, 3000) }
    $command = ''
    try {
        $last = Get-History -Count 1
        if ($last) { $command = [string]$last.CommandLine }
    } catch { }
    $request = 'Explain this PowerShell error and how to fix it.'
    if ($command) { $request = $request + "`nThe command I ran: " + $command }
    $request = $request + "`nThe error:`n" + $text
    Write-Host ''
    Write-PsaiNote 'Explaining this error:'
    foreach ($errorLine in ($text.Split([char]10) | Select-Object -First 6)) { Write-Host ('    ' + $errorLine.TrimEnd()) -ForegroundColor DarkGray }
    Invoke-PsaiAsk -Config $Config -Request $request -SystemPrompt (Get-PsaiExplainPrompt)
}

function Start-PsaiChat {
    param($Config, $Resume = $null)
    Write-Host ''
    Write-Host ('  psai chat - ' + $Config['Model'] + ' on ' + (Get-PsaiProviderName $Config)) -ForegroundColor Cyan
    Write-PsaiNote 'Type /help for commands and /exit to leave. Esc stops a reply.'

    $messages = New-Object System.Collections.Generic.List[object]
    $messages.Add(@{ role = 'system'; content = (Get-PsaiChatPrompt) })
    $record = $Resume
    if ($record) {
        foreach ($m in $record.Log) { $messages.Add($m) }
        Show-PsaiResumeSummary $record
    } else {
        $record = New-PsaiChatRecord -Mode 'chat' -Root ''
        try { Remove-PsaiOldChats $Config } catch { }
    }

    while ($true) {
        $line = Read-PsaiInput -Label 'you' -Color 'Green'
        if ($null -eq $line) { break }
        $text = $line.Trim()
        if ($text -eq '') { continue }
        $lower = $text.ToLowerInvariant()
        if ($lower -eq '/exit' -or $lower -eq '/quit' -or $lower -eq '/q' -or $lower -eq 'exit' -or $lower -eq 'quit') { break }
        if ($lower -eq '/clear') {
            [void](Save-PsaiChat -Record $record -Messages $messages -Config $Config)
            while ($messages.Count -gt 1) { $messages.RemoveAt(1) }
            $record = New-PsaiChatRecord -Mode 'chat' -Root ''
            Write-PsaiNote 'Started a new conversation. The old one is saved (psai /history).'
            continue
        }
        if ($lower -eq '/help') {
            Show-PsaiReplHelp
            continue
        }
        if (Invoke-PsaiSaveCommand -Text $text -Record $record -Messages $messages -Config $Config) { continue }
        if ($lower -eq '/model') {
            [void](Update-PsaiModelChoice -Config $Config)
            continue
        }
        if ($lower.StartsWith('/', [StringComparison]::Ordinal) -and $lower.IndexOf(' ') -lt 0) {
            Write-PsaiNote ('Unknown command ' + $text + '. Type /help to see the commands.')
            continue
        }

        $messages.Add(@{ role = 'user'; content = $text; task = $true })
        Limit-PsaiHistory -Messages $messages -Config $Config
        Write-Host ''
        $res = $null
        try {
            $res = Invoke-PsaiModel -Config $Config -Messages $messages
        } catch {
            Write-PsaiError $_.Exception.Message
            $messages.RemoveAt($messages.Count - 1)
            continue
        }
        if ($res.content) {
            $messages.Add(@{ role = 'assistant'; content = $res.content })
        } else {
            $messages.RemoveAt($messages.Count - 1)
        }
        if ($res.cancelled) { Write-PsaiNote '(stopped)' }
        elseif (-not $res.content) { Write-PsaiNote '(the model gave an empty answer)' }
        [void](Save-PsaiChat -Record $record -Messages $messages -Config $Config)
    }
}
