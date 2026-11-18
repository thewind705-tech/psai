# Saved chats: every chat and /code session is saved to ~\.psai\chats as
#   <id>.json  (used by psai /resume)
#   <id>.md    (a readable transcript)
# The model's context may drop old messages, but the saved log keeps the whole conversation.

function Get-PsaiChatsDir {
    return [System.IO.Path]::Combine($HOME, '.psai', 'chats')
}

# A record for one conversation. Mode is 'chat' or 'code'; Root is the project folder for 'code'.
function New-PsaiChatRecord {
    param([string]$Mode, [string]$Root)
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 4)
    return @{
        Id      = $stamp + '-' + $Mode + '-' + $suffix
        Mode    = $Mode
        Root    = $Root
        Name    = ''
        Created = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Log     = (New-Object System.Collections.Generic.List[object])
        Seen    = (New-Object 'System.Collections.Generic.HashSet[object]')
    }
}

# Adds messages that are new since the last save to the record's log.
function Update-PsaiChatLog {
    param($Record, $Messages)
    foreach ($m in $Messages) {
        if ($m.role -eq 'system') { continue }
        if ($Record.Seen.Add($m)) { $Record.Log.Add($m) }
    }
}

function Get-PsaiChatTitle {
    param($Record)
    if ($Record.Name) { return [string]$Record.Name }
    foreach ($m in $Record.Log) {
        if ($m.role -eq 'user' -and $m.task) {
            $first = ([string]$m.content).Trim().Split([char]10)[0].Trim()
            if ($first.Length -gt 60) { $first = $first.Substring(0, 57) + '...' }
            return $first
        }
    }
    return '(empty)'
}

# Saves the conversation. Does nothing until the user has said something,
# unless -Force is given. Returns the path of the .json file, or $null.
function Save-PsaiChat {
    param($Record, $Messages, $Config, [switch]$Force)
    if ($null -eq $Record) { return $null }
    if (-not $Force -and $Config -and $Config['SaveChats'] -eq $false) { return $null }
    Update-PsaiChatLog -Record $Record -Messages $Messages
    $hasUser = $false
    foreach ($m in $Record.Log) { if ($m.role -eq 'user') { $hasUser = $true; break } }
    if (-not $hasUser) { return $null }
    try {
        $dir = Get-PsaiChatsDir
        if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
        $model = ''
        if ($Config) { $model = [string]$Config['Model'] }
        $data = [ordered]@{
            Version  = 1
            Mode     = $Record.Mode
            Name     = $Record.Name
            Title    = (Get-PsaiChatTitle $Record)
            Created  = $Record.Created
            Updated  = (Get-Date).ToString('yyyy-MM-dd HH:mm')
            Model    = $model
            Root     = $Record.Root
            Messages = $Record.Log.ToArray()
        }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $jsonPath = [System.IO.Path]::Combine($dir, $Record.Id + '.json')
        [System.IO.File]::WriteAllText($jsonPath, (ConvertTo-PsaiJson $data), $utf8)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($dir, $Record.Id + '.md'), (ConvertTo-PsaiTranscript $data), $utf8)
        return $jsonPath
    } catch {
        Write-PsaiNote ('(could not save this chat: ' + $_.Exception.Message + ')')
        return $null
    }
}

function ConvertTo-PsaiTranscript {
    param($Data)
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('# ' + $Data.Title)
    $out.Add('')
    $about = 'psai ' + $Data.Mode + ', ' + $Data.Created + ', model ' + $Data.Model
    if ($Data.Root) { $about = $about + ', folder ' + $Data.Root }
    $out.Add('_' + $about + '_')
    foreach ($m in $Data.Messages) {
        $out.Add('')
        if ($m.role -eq 'user' -and $m.task) {
            $out.Add('**You:**')
            $out.Add([string]$m.content)
        } elseif ($m.role -eq 'assistant') {
            if ($m.content) {
                $out.Add('**psai:**')
                $out.Add([string]$m.content)
            }
            if ($m.tool_calls) {
                foreach ($tc in $m.tool_calls) {
                    $summary = [string]$tc.name
                    if ($tc.arguments -and $tc.arguments['path']) { $summary = $summary + ' ' + [string]$tc.arguments['path'] }
                    if ($tc.arguments -and $tc.arguments['command']) { $summary = $summary + ': ' + ([string]$tc.arguments['command']).Split([char]10)[0] }
                    $out.Add('> tool: ' + $summary)
                }
            }
        } else {
            $text = ([string]$m.content).Trim()
            if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
            $out.Add('> result: ' + $text.Replace("`n", "`n> "))
        }
    }
    return (($out -join "`n") + "`n")
}

# Deletes the oldest unnamed saved chats beyond MaxSavedChats.
function Remove-PsaiOldChats {
    param($Config)
    $keep = [int]$Config['MaxSavedChats']
    if ($keep -le 0) { return }
    $chats = Get-PsaiChatList
    $unnamed = @($chats | Where-Object { -not $_.Name })
    for ($i = $keep; $i -lt $unnamed.Count; $i++) {
        $base = $unnamed[$i].Path.Substring(0, $unnamed[$i].Path.Length - 5)
        Remove-Item -LiteralPath ($base + '.json') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($base + '.md') -Force -ErrorAction SilentlyContinue
    }
}

# Saved chats, newest first, as @{ Path; Mode; Name; Title; Updated; Count; Root }.
function Get-PsaiChatList {
    $list = New-Object System.Collections.Generic.List[object]
    $dir = Get-PsaiChatsDir
    if (-not [System.IO.Directory]::Exists($dir)) { return , $list.ToArray() }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    foreach ($f in $files) {
        # Read the summary fields straight from the text: parsing every saved
        # conversation in full would make the list slow on Windows PowerShell.
        $text = ''
        try { $text = [System.IO.File]::ReadAllText($f.FullName) } catch { continue }
        $head = $text
        if ($head.Length -gt 4000) { $head = $head.Substring(0, 4000) }
        $mode = Get-PsaiJsonField $head 'Mode'
        if (-not $mode) { continue }
        $list.Add(@{
                Path    = $f.FullName
                Mode    = $mode
                Name    = (Get-PsaiJsonField $head 'Name')
                Title   = (Get-PsaiJsonField $head 'Title')
                Updated = (Get-PsaiJsonField $head 'Updated')
                Count   = [regex]::Matches($text, '"role":"(user|assistant)"').Count
                Root    = (Get-PsaiJsonField $head 'Root')
            })
    }
    return , $list.ToArray()
}

# Reads one top-level string field from the start of a saved chat file.
function Get-PsaiJsonField {
    param([string]$Text, [string]$Name)
    $m = [regex]::Match($Text, '"' + $Name + '":"((?:[^"\\]|\\.)*)"')
    if (-not $m.Success) { return '' }
    try { return [regex]::Unescape($m.Groups[1].Value) } catch { return $m.Groups[1].Value }
}

# Loads a saved chat back into a record, ready to continue.
function Read-PsaiChat {
    param([string]$Path)
    $data = ConvertFrom-PsaiJsonSafe ([System.IO.File]::ReadAllText($Path))
    if ($null -eq $data) { throw ('This saved chat could not be read: ' + $Path) }
    $record = New-PsaiChatRecord -Mode ([string]$data.Mode) -Root ([string]$data.Root)
    $record.Id = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $record.Name = [string]$data.Name
    if ($data.Created) { $record.Created = [string]$data.Created }
    foreach ($item in @($data.Messages)) {
        if ($null -eq $item) { continue }
        $m = ConvertTo-PsaiMap $item
        if (-not ($m -is [hashtable])) { continue }
        if ($m['tool_calls']) { $m['tool_calls'] = @($m['tool_calls']) }
        $record.Log.Add($m)
        [void]$record.Seen.Add($m)
    }
    return $record
}

function Show-PsaiHistory {
    $chats = Get-PsaiChatList
    Write-Host ''
    if ($chats.Count -eq 0) {
        Write-PsaiNote 'There are no saved chats yet. They are saved automatically while you use psai.'
        return
    }
    Write-Host '  Saved chats, newest first:' -ForegroundColor Cyan
    $shown = [Math]::Min($chats.Count, 20)
    for ($i = 0; $i -lt $shown; $i++) {
        $c = $chats[$i]
        $title = $c.Title
        if ($c.Name) { $title = $c.Name }
        $label = '    [' + ($i + 1) + '] ' + $c.Updated + '  ' + $c.Mode.PadRight(5) + $title
        Write-Host -NoNewline $label
        $extra = '  (' + $c.Count + ' messages'
        if ($c.Mode -eq 'code' -and $c.Root) { $extra = $extra + ', ' + $c.Root }
        Write-Host ($extra + ')') -ForegroundColor DarkGray
    }
    if ($chats.Count -gt $shown) { Write-PsaiNote ('... and ' + ($chats.Count - $shown) + ' older ones') }
    Write-Host ''
    Write-PsaiNote 'psai /resume continues the newest one, psai /resume 3 continues number 3.'
    Write-PsaiNote ('psai /history open shows the folder: ' + (Get-PsaiChatsDir))
}

function Open-PsaiChatsFolder {
    $dir = Get-PsaiChatsDir
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    if ($env:OS -eq 'Windows_NT') { Invoke-Item -LiteralPath $dir } else { Write-Host $dir }
}

# Picks a saved chat by its number in psai /history (1 = newest). Returns its path or $null.
function Find-PsaiSavedChat {
    param([string]$Which)
    $chats = Get-PsaiChatList
    if ($chats.Count -eq 0) {
        Write-PsaiNote 'There are no saved chats yet.'
        return $null
    }
    $number = 1
    if ($Which) {
        if (-not [int]::TryParse($Which, [ref]$number) -or $number -lt 1 -or $number -gt $chats.Count) {
            Write-PsaiError ('There is no saved chat number ' + $Which + '. Run psai /history to see the list.')
            return $null
        }
    }
    return $chats[$number - 1].Path
}

# Prints the last exchange of a resumed chat so you know where you left off.
function Show-PsaiResumeSummary {
    param($Record)
    $title = Get-PsaiChatTitle $Record
    Write-PsaiNote ('Continuing "' + $title + '" (' + $Record.Log.Count + ' messages, started ' + $Record.Created + ')')
    $lastUser = $null
    $lastAnswer = $null
    foreach ($m in $Record.Log) {
        if ($m.role -eq 'user' -and $m.task) { $lastUser = $m; $lastAnswer = $null }
        elseif ($m.role -eq 'assistant' -and $m.content) { $lastAnswer = $m }
    }
    foreach ($pair in @(@('you: ', $lastUser), @('psai: ', $lastAnswer))) {
        if ($null -eq $pair[1]) { continue }
        $text = ([string]$pair[1].content).Trim().Replace("`r", '').Replace("`n", ' ')
        if ($text.Length -gt 200) { $text = $text.Substring(0, 197) + '...' }
        Write-PsaiNote ($pair[0] + $text)
    }
}

# Handles "/save" or "/save some name" typed in chat or /code. Returns $true when it was one.
function Invoke-PsaiSaveCommand {
    param([string]$Text, $Record, $Messages, $Config)
    $lower = $Text.ToLowerInvariant()
    if (-not ($lower -eq '/save' -or $lower.StartsWith('/save ', [StringComparison]::Ordinal))) { return $false }
    $name = $Text.Substring(5).Trim()
    if ($name) { $Record.Name = $name }
    $path = Save-PsaiChat -Record $Record -Messages $Messages -Config $Config -Force
    if ($path) {
        Write-PsaiNote ('Saved: ' + [System.IO.Path]::ChangeExtension($path, '.md'))
    } else {
        Write-PsaiNote 'Nothing to save yet.'
    }
    return $true
}
