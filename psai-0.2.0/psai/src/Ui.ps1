# Terminal output and input: messages, prompts, the streaming text renderer and diffs.

function Write-PsaiError {
    param([string]$Message)
    Write-Host ('  ' + $Message) -ForegroundColor Red
}

function Write-PsaiNote {
    param([string]$Message)
    Write-Host ('  ' + $Message) -ForegroundColor DarkGray
}

# True when $Text contains $Find, ignoring case the same way on every system language.
function Test-PsaiText {
    param([string]$Text, [string]$Find)
    if (-not $Text -or -not $Find) { return $false }
    return ($Text.IndexOf($Find, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

# Regex match that ignores case without depending on the system language
# (PowerShell's -match follows it, which breaks "i"/"I" on Turkish Windows).
function Test-PsaiMatch {
    param([string]$Text, [string]$Pattern)
    if ($null -eq $Text) { return $false }
    return [regex]::IsMatch($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')
}

$script:PsaiRiskyPattern = '(?<![\w-])(Remove-Item|rm|rmdir|del|erase|rd|ri|Clear-Content|Clear-RecycleBin|Format-Volume|Format-Disk|Clear-Disk|Initialize-Disk|Stop-Computer|Restart-Computer|Remove-ItemProperty|Remove-LocalUser|Set-ExecutionPolicy|Stop-Process|taskkill|diskpart|reg\s+delete|git\s+reset\s+--hard|git\s+clean|git\s+push\s+.*--force)(?![\w-])'

# True when a command looks like it deletes or changes things (used only for a warning).
function Test-PsaiRisky {
    param([string]$Command)
    return (Test-PsaiMatch $Command $script:PsaiRiskyPattern)
}

# Shortens long text, keeping the start and the end.
function Limit-PsaiText {
    param([string]$Text, [int]$Max)
    if ($Max -le 0) { $Max = 12000 }
    if ($Text.Length -le $Max) { return $Text }
    $head = [int][Math]::Floor($Max * 0.6)
    $tail = $Max - $head
    return ($Text.Substring(0, $head) + "`n... [" + ($Text.Length - $Max) + " characters left out] ...`n" + $Text.Substring($Text.Length - $tail))
}

# --------------------------------------------------------------------------- input --

# Asks until the user types one of the allowed answers. Only the first letter counts,
# so "yes" works as "y". An empty answer returns $Default (when it is not empty).
function Read-PsaiChoice {
    param([string]$Prompt, [string[]]$Allowed, [string]$Default)
    while ($true) {
        Write-Host -NoNewline $Prompt -ForegroundColor Yellow
        $answer = Read-Host
        if ($null -eq $answer) { return $Default }
        $answer = $answer.Trim().ToLowerInvariant()
        if ($answer -eq '' -and $Default) { return $Default }
        if ($answer.Length -gt 0) {
            $first = $answer.Substring(0, 1)
            if ($Allowed -contains $first) { return $first }
        }
        Write-PsaiNote ('Please type one of: ' + ($Allowed -join ', '))
    }
}

function Read-PsaiLine {
    param([string]$Prompt, [string]$Color = 'Gray')
    Write-Host -NoNewline $Prompt -ForegroundColor $Color
    $line = Read-Host
    if ($null -eq $line) { return '' }
    return $line.Trim()
}

# Reads a chat message. Pasted multi-line text is joined into one message, and
# a line with only """ starts and ends a multi-line message.
function Read-PsaiInput {
    param([string]$Label, [string]$Color = 'Green')
    Write-Host ''
    Write-Host -NoNewline ($Label + '> ') -ForegroundColor $Color
    $line = Read-Host
    if ($null -eq $line) { return $null }
    if ($line.Trim() -eq '"""') {
        $block = New-Object System.Collections.Generic.List[string]
        while ($true) {
            Write-Host -NoNewline '... ' -ForegroundColor DarkGray
            $next = Read-Host
            if ($null -eq $next -or $next.Trim() -eq '"""') { break }
            $block.Add($next)
        }
        return ($block -join "`n")
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($line)
    if ($script:PsaiCanReadKeys) {
        try {
            Start-Sleep -Milliseconds 40
            while ([Console]::KeyAvailable) {
                $lines.Add((Read-Host))
                Start-Sleep -Milliseconds 40
            }
        } catch { }
    }
    return ($lines -join "`n")
}

# ------------------------------------------------------------------ streaming renderer --
# Prints the model's reply as it arrives: wraps prose at word boundaries, shows code
# blocks in cyan, hides the ``` fence noise in gray and drops **bold** markers.

function New-PsaiRenderer {
    $width = 100
    try { $width = [int]$Host.UI.RawUI.WindowSize.Width } catch { }
    if ($width -lt 40) { $width = 100 }
    return @{
        Width     = $width
        Col       = 0
        LineStart = $true
        Pending   = ''
        InCode    = $false
        FenceLine = $false
        Word      = ''
        Out       = (New-Object System.Text.StringBuilder)
        OutColor  = ''
    }
}

function Add-PsaiOut {
    param($R, [string]$Text, [string]$Color)
    if ($Text.Length -eq 0) { return }
    if ($R.Out.Length -gt 0 -and $R.OutColor -ne $Color) { Send-PsaiOut $R }
    $R.OutColor = $Color
    [void]$R.Out.Append($Text)
}

function Send-PsaiOut {
    param($R)
    if ($R.Out.Length -eq 0) { return }
    $text = $R.Out.ToString()
    [void]$R.Out.Clear()
    if ($R.OutColor) {
        Write-Host -NoNewline $text -ForegroundColor $R.OutColor
    } else {
        Write-Host -NoNewline $text
    }
}

function Send-PsaiWord {
    param($R)
    if ($R.Word.Length -eq 0) { return }
    $word = $R.Word.Replace('**', '')
    $R.Word = ''
    if ($word.Length -eq 0) { return }
    if ($R.Col -gt 0 -and ($R.Col + $word.Length) -ge $R.Width) {
        Add-PsaiOut $R "`n" ''
        $R.Col = 0
    }
    Add-PsaiOut $R $word ''
    $R.Col = ($R.Col + $word.Length) % $R.Width
}

function Add-PsaiRenderPlain {
    param($R, [string]$Text)
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($R.InCode) {
            Add-PsaiOut $R ([string]$c) 'Cyan'
            if ($c -eq [char]10) {
                $R.LineStart = $true
                $R.Col = 0
            } else {
                $R.Col = $R.Col + 1
            }
            continue
        }
        if ($c -eq [char]10) {
            Send-PsaiWord $R
            Add-PsaiOut $R "`n" ''
            $R.Col = 0
            $R.LineStart = $true
        } elseif ($c -eq [char]32 -or $c -eq [char]9) {
            Send-PsaiWord $R
            if ($R.Col -ge ($R.Width - 1)) {
                Add-PsaiOut $R "`n" ''
                $R.Col = 0
            } else {
                Add-PsaiOut $R ([string]$c) ''
                $R.Col = $R.Col + 1
            }
        } else {
            $R.Word = $R.Word + $c
            if ($R.Word.Length -ge ($R.Width - 1)) { Send-PsaiWord $R }
        }
    }
}

function Add-PsaiRenderText {
    param($R, [string]$Text)
    $tick = [string][char]96
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -eq [char]13) { continue }

        # At the start of a line, hold the first characters until we know whether
        # the line is a ``` code fence.
        if ($R.LineStart) {
            $R.Pending = $R.Pending + $c
            $t = $R.Pending.TrimStart([char]32)
            if ($c -eq [char]10) {
                $p = $R.Pending
                $R.Pending = ''
                $R.LineStart = $false
                Add-PsaiRenderPlain $R $p
                continue
            }
            if ($t.Length -ge 3 -and $t.StartsWith(($tick * 3), [StringComparison]::Ordinal)) {
                $R.LineStart = $false
                $R.FenceLine = $true
                Add-PsaiOut $R $R.Pending 'DarkGray'
                $R.Col = $R.Pending.Length
                $R.Pending = ''
            } elseif ($t.Length -gt 0 -and $t.Replace($tick, '').Length -gt 0) {
                $p = $R.Pending
                $R.Pending = ''
                $R.LineStart = $false
                Add-PsaiRenderPlain $R $p
            }
            continue
        }

        if ($R.FenceLine) {
            Add-PsaiOut $R ([string]$c) 'DarkGray'
            if ($c -eq [char]10) {
                $R.FenceLine = $false
                $R.InCode = -not $R.InCode
                $R.LineStart = $true
                $R.Col = 0
            } else {
                $R.Col = $R.Col + 1
            }
            continue
        }

        Add-PsaiRenderPlain $R ([string]$c)
    }
    Send-PsaiOut $R
}

function Complete-PsaiRender {
    param($R)
    if ($R.Pending.Length -gt 0) {
        $p = $R.Pending
        $R.Pending = ''
        $R.LineStart = $false
        Add-PsaiRenderPlain $R $p
    }
    Send-PsaiWord $R
    if (-not $R.LineStart) {
        Add-PsaiOut $R "`n" ''
        $R.Col = 0
        $R.LineStart = $true
    }
    Send-PsaiOut $R
}

# --------------------------------------------------------------------------- diffs --

# Shows what changes between two texts: a few unchanged lines around the changed block,
# removed lines in red and added lines in green. Returns the first changed line number.
function Show-PsaiDiff {
    param([string]$Old, [string]$New, [int]$MaxLines = 60)
    $a = $Old.Replace("`r`n", "`n").Split([char]10)
    $b = $New.Replace("`r`n", "`n").Split([char]10)

    $prefix = 0
    while ($prefix -lt $a.Length -and $prefix -lt $b.Length -and [string]::Equals($a[$prefix], $b[$prefix])) { $prefix++ }
    $suffix = 0
    while ($suffix -lt ($a.Length - $prefix) -and $suffix -lt ($b.Length - $prefix) -and
        [string]::Equals($a[$a.Length - 1 - $suffix], $b[$b.Length - 1 - $suffix])) { $suffix++ }

    $removedEnd = $a.Length - $suffix
    $addedEnd = $b.Length - $suffix
    $removedCount = $removedEnd - $prefix
    $addedCount = $addedEnd - $prefix

    if ($removedCount + $addedCount -le $MaxLines) {
        $showRemoved = $removedCount
        $showAdded = $addedCount
    } else {
        $half = [int][Math]::Floor($MaxLines / 2)
        if ($removedCount -lt $half) {
            $showRemoved = $removedCount
            $showAdded = $MaxLines - $removedCount
        } elseif ($addedCount -lt $half) {
            $showAdded = $addedCount
            $showRemoved = $MaxLines - $addedCount
        } else {
            $showRemoved = $half
            $showAdded = $half
        }
    }

    $contextStart = [Math]::Max(0, $prefix - 3)
    for ($i = $contextStart; $i -lt $prefix; $i++) { Write-Host ('    ' + $a[$i]) -ForegroundColor DarkGray }
    for ($i = 0; $i -lt $removedCount; $i++) {
        if ($i -ge $showRemoved) {
            Write-PsaiNote ('  ... ' + ($removedCount - $i) + ' more removed lines')
            break
        }
        Write-Host ('  - ' + $a[$prefix + $i]) -ForegroundColor Red
    }
    for ($i = 0; $i -lt $addedCount; $i++) {
        if ($i -ge $showAdded) {
            Write-PsaiNote ('  ... ' + ($addedCount - $i) + ' more added lines')
            break
        }
        Write-Host ('  + ' + $b[$prefix + $i]) -ForegroundColor Green
    }
    $contextEnd = [Math]::Min($b.Length, $addedEnd + 3)
    for ($i = $addedEnd; $i -lt $contextEnd; $i++) { Write-Host ('    ' + $b[$i]) -ForegroundColor DarkGray }
    Write-PsaiNote ('(' + $addedCount + ' lines added, ' + $removedCount + ' removed)')
    return ($prefix + 1)
}

function Show-PsaiNewFile {
    param([string]$Text, [int]$MaxLines = 40)
    $lines = $Text.Replace("`r`n", "`n").Split([char]10)
    $count = $lines.Length
    if ($count -gt 0 -and $lines[$count - 1] -eq '') { $count-- }
    for ($i = 0; $i -lt $count; $i++) {
        if ($i -ge $MaxLines) {
            Write-PsaiNote ('  ... ' + ($count - $i) + ' more lines')
            break
        }
        Write-Host ('  + ' + $lines[$i]) -ForegroundColor Green
    }
    Write-PsaiNote ('(new file, ' + $count + ' lines)')
}

# --------------------------------------------------------------------------- help --

function Show-PsaiHelp {
    Write-Host ''
    Write-Host '  psai - an AI assistant for PowerShell, running on your own computer' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  psai "what you want to do"   suggest a PowerShell command, then run or copy it'
    Write-Host '  psai                         chat (type /exit to leave)'
    Write-Host '  psai /code [task]            coding agent for the current folder'
    Write-Host '  psai /explain                explain the last error in this window'
    Write-Host '  psai /model                  pick another model'
    Write-Host '  psai /status                 show settings and check the server'
    Write-Host '  psai /config                 open the settings file'
    Write-Host '  psai /setup                  run the first-time setup again'
    Write-Host '  psai /history                list saved chats (psai /history open shows the folder)'
    Write-Host '  psai /resume [number]        continue the newest saved chat, or number N from /history'
    Write-Host ''
    Write-Host '  In chat and /code:  /save [name]  /clear  /model  /help  /exit     Esc stops a reply'
    Write-Host '  Pasting several lines sends them as one message. You can also type """'
    Write-Host '  on its own line to start and end a multi-line message.'
    Write-Host ''
    Write-Host '  Put your request in quotes: characters like | > ; $ ( ) mean something to PowerShell.' -ForegroundColor DarkGray
}

function Show-PsaiReplHelp {
    param([switch]$Agent)
    Write-Host ''
    Write-Host '  /save    save now; /save my name gives it a name (chats also save on their own)'
    Write-Host '  /clear   start a new conversation (the old one stays saved)'
    Write-Host '  /model   switch to another model'
    Write-Host '  /exit    leave'
    Write-Host '  Esc      stop the current reply'
    Write-Host '  """      start or end a multi-line message'
    if ($Agent) {
        Write-Host ''
        Write-Host '  When psai wants to change a file or run a command it asks first:'
        Write-Host '  y = yes, n = no (you can say what to do instead), a = yes to all file edits'
        Write-Host '  for this task, s = stop the task.'
    }
}
