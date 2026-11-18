# psai /code: a small coding agent for the current folder.
# The model can look at files, edit them and run commands through six tools.
# Every file change and every command needs the user's OK first.

$script:PsaiSkipDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($psaiDirName in @('.git', '.hg', '.svn', 'node_modules', 'bin', 'obj', '.vs', '.idea', '__pycache__', '.venv', 'venv',
        '.mypy_cache', '.pytest_cache', '.next', '.nuxt', 'dist', 'build', 'target', 'packages', '.gradle', 'coverage')) {
    [void]$script:PsaiSkipDirs.Add($psaiDirName)
}

$script:PsaiBinaryExtensions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($psaiExt in @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.webp', '.pdf', '.zip', '.7z', '.rar', '.gz', '.tar',
        '.exe', '.dll', '.pdb', '.so', '.dylib', '.bin', '.obj', '.o', '.a', '.lib', '.class', '.jar', '.pyc', '.woff', '.woff2',
        '.ttf', '.otf', '.eot', '.mp3', '.mp4', '.wav', '.avi', '.mov', '.mkv', '.db', '.sqlite', '.nupkg', '.snk', '.pfx')) {
    [void]$script:PsaiBinaryExtensions.Add($psaiExt)
}

# --------------------------------------------------------------------- tool definitions --

function New-PsaiToolDef {
    param([string]$Name, [string]$Description, $Properties, [string[]]$Required)
    $requiredList = @()
    if ($Required) { $requiredList = @($Required) }
    return [ordered]@{
        type       = 'function'
        'function' = [ordered]@{
            name        = $Name
            description = $Description
            parameters  = [ordered]@{
                type       = 'object'
                properties = $Properties
                required   = $requiredList
            }
        }
    }
}

function Get-PsaiToolDefinitions {
    $tools = New-Object System.Collections.Generic.List[object]
    $tools.Add((New-PsaiToolDef -Name 'list_files' -Required @() `
                -Description 'List the folders and files of the project as a tree. Skips folders such as .git, node_modules, bin and obj.' `
                -Properties ([ordered]@{
                    path  = @{ type = 'string'; description = 'Folder to list, relative to the project folder. Leave it out for the project folder.' }
                    depth = @{ type = 'integer'; description = 'How many folder levels to show, 1 to 6. Default 3.' }
                })))
    $tools.Add((New-PsaiToolDef -Name 'read_file' -Required @('path') `
                -Description 'Read a text file. Long files come back in parts; use start_line to read further.' `
                -Properties ([ordered]@{
                    path       = @{ type = 'string'; description = 'File path relative to the project folder.' }
                    start_line = @{ type = 'integer'; description = 'First line to read (1 = first line). Optional.' }
                    end_line   = @{ type = 'integer'; description = 'Last line to read. Optional.' }
                })))
    $tools.Add((New-PsaiToolDef -Name 'search' -Required @('pattern') `
                -Description 'Search the text of all files in the project (case-insensitive regular expression). Returns lines as path:line: text.' `
                -Properties ([ordered]@{
                    pattern = @{ type = 'string'; description = 'Text or regular expression to look for.' }
                    path    = @{ type = 'string'; description = 'Folder or file to search in, relative to the project folder. Optional.' }
                })))
    $tools.Add((New-PsaiToolDef -Name 'write_file' -Required @('path', 'content') `
                -Description 'Create a new file, or replace the whole content of an existing file. The user must approve it.' `
                -Properties ([ordered]@{
                    path    = @{ type = 'string'; description = 'File path relative to the project folder. Missing folders are created.' }
                    content = @{ type = 'string'; description = 'The complete new content of the file.' }
                })))
    $tools.Add((New-PsaiToolDef -Name 'edit_file' -Required @('path', 'old_text', 'new_text') `
                -Description 'Change part of an existing file: replaces old_text with new_text. old_text must be copied exactly from the file and must appear only once. The user must approve it.' `
                -Properties ([ordered]@{
                    path     = @{ type = 'string'; description = 'File path relative to the project folder.' }
                    old_text = @{ type = 'string'; description = 'The exact lines to replace, including indentation. Include enough lines to be unique.' }
                    new_text = @{ type = 'string'; description = 'The text to put in their place.' }
                })))
    $tools.Add((New-PsaiToolDef -Name 'run_command' -Required @('command') `
                -Description 'Run a PowerShell command in the project folder and get its output (tests, builds, git, package managers). Each command runs in a new PowerShell process. The user must approve it.' `
                -Properties ([ordered]@{
                    command = @{ type = 'string'; description = 'The PowerShell command to run. It must not wait for keyboard input.' }
                })))
    return , $tools.ToArray()
}

# Tool descriptions for models without built-in tool support (they get them as text).
function Get-PsaiToolDocs {
    param($Tools)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($tool in $Tools) {
        $fn = $tool['function']
        $lines.Add('- ' + $fn['name'] + ': ' + $fn['description'])
        $required = @($fn['parameters']['required'])
        foreach ($key in @($fn['parameters']['properties'].Keys)) {
            $prop = $fn['parameters']['properties'][$key]
            $flag = 'optional'
            if ($required -contains $key) { $flag = 'required' }
            $lines.Add('    "' + $key + '" (' + $prop['type'] + ', ' + $flag + '): ' + $prop['description'])
        }
    }
    return ($lines -join "`n")
}

function Get-PsaiAgentPrompt {
    param($Session)
    $shell = Get-PsaiShellName
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('You are psai, a coding agent. You work in a project folder on the user''s computer and change it only through your tools.')
    $lines.Add('')
    $lines.Add('Project folder: ' + $Session.Root)
    $lines.Add('Shell: ' + $shell + ' on ' + (Get-PsaiOsName))
    $lines.Add('Today: ' + (Get-Date).ToString('yyyy-MM-dd'))
    $lines.Add('')
    $lines.Add('How to work:')
    $lines.Add('1. Look before you change anything: use list_files, search and read_file on the files that matter. Never guess what a file contains.')
    $lines.Add('2. Make small, focused changes. To change an existing file use edit_file, copying old_text exactly from read_file output (same spaces and indentation). Use write_file for new files.')
    $lines.Add('3. Paths are relative to the project folder. Use forward slashes, for example src/app.js.')
    $lines.Add('4. run_command starts a fresh PowerShell process in the project folder each time. Use PowerShell syntax, not bash.' + (Get-PsaiShellLimits) + ' Commands must not wait for keyboard input.')
    $lines.Add('5. The user approves every file change and every command. If they say no, read their feedback and change your plan; do not repeat the same change.')
    $lines.Add('6. When the task is done, stop calling tools and reply with a short summary of what you changed and anything the user should do next.')
    $lines.Add('Reply in the language the user writes in. Keep your messages short.')
    if ($Session.TextMode) {
        $lines.Add('')
        $lines.Add('To use a tool, reply with a block like this and nothing after it:')
        $lines.Add('<tool_call>')
        $lines.Add('{"name": "read_file", "arguments": {"path": "src/app.js"}}')
        $lines.Add('</tool_call>')
        $lines.Add('Use one tool per reply, then wait: the result comes back in the next message.')
        $lines.Add('')
        $lines.Add('Tools:')
        $lines.Add((Get-PsaiToolDocs $Session.Tools))
    }
    $lines.Add('')
    $lines.Add('The project folder right now (2 levels):')
    $lines.Add($Session.Overview)
    return (($lines -join "`n") + (Get-PsaiCustomPrompt 'code'))
}

# Models that print tool calls as text (in <tool_call> tags or a JSON block) instead of
# using the built-in tool format still work: psai reads the calls from the text.
function Get-PsaiTextToolCalls {
    param([string]$Text, $KnownNames)
    $calls = New-Object System.Collections.Generic.List[object]
    if (-not $Text) { return , $calls }
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($Text, '(?s)<tool_call>\s*(.*?)\s*</tool_call>')) { $candidates.Add($m.Groups[1].Value) }
    if ($candidates.Count -eq 0) {
        foreach ($m in [regex]::Matches($Text, '(?s)```(?:json)?\s*(\{.*?\})\s*```')) { $candidates.Add($m.Groups[1].Value) }
    }
    if ($candidates.Count -eq 0) {
        $whole = $Text.Trim()
        if ($whole.StartsWith('{', [StringComparison]::Ordinal) -and $whole.EndsWith('}', [StringComparison]::Ordinal)) { $candidates.Add($whole) }
    }
    foreach ($candidate in $candidates) {
        $map = ConvertTo-PsaiArguments $candidate
        if ($null -eq $map) { continue }
        $name = [string]$map['name']
        if (-not ($KnownNames -contains $name)) { continue }
        $callArgs = $map['arguments']
        if ($null -eq $callArgs) { $callArgs = $map['parameters'] }
        if ($callArgs -is [string]) { $callArgs = ConvertTo-PsaiArguments $callArgs }
        if (-not ($callArgs -is [hashtable])) { $callArgs = New-PsaiMap }
        $calls.Add(@{ id = (New-PsaiCallId); name = $name; arguments = $callArgs; error = $null })
    }
    return , $calls
}

function Enable-PsaiTextToolMode {
    param($Session)
    $Session.TextMode = $true
    $Session.Messages[0] = @{ role = 'system'; content = (Get-PsaiAgentPrompt $Session) }
}

# ----------------------------------------------------------------------- path helpers --

# Turns a path from the model into a full path and makes sure it stays in the project.
function Resolve-PsaiPath {
    param([string]$Root, [string]$Path)
    $p = ([string]$Path).Trim().Trim('"', "'")
    if ($p -eq '' -or $p -eq '.' -or $p -eq './' -or $p -eq '.\' -or $p -eq '/' -or $p -eq '\') { return $Root }
    $full = $null
    if ($p.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
        $full = [System.IO.Path]::GetFullPath($p)
    } elseif ([System.IO.Path]::IsPathRooted($p) -and -not ($p.StartsWith('/', [StringComparison]::Ordinal) -or $p.StartsWith('\', [StringComparison]::Ordinal))) {
        $full = [System.IO.Path]::GetFullPath($p)
    } else {
        $full = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Root, $p.TrimStart('/', '\')))
    }
    $full = $full.TrimEnd('/', '\')
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    if (-not ([string]::Equals($full, $Root, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($Root + $sep, [StringComparison]::OrdinalIgnoreCase))) {
        throw ($Path + ' is outside the project folder. Only paths inside ' + $Root + ' can be used.')
    }
    return $full
}

function Get-PsaiRelPath {
    param([string]$Root, [string]$Full)
    if ([string]::Equals($Root, $Full, [StringComparison]::OrdinalIgnoreCase)) { return '.' }
    return $Full.Substring($Root.Length).TrimStart('/', '\').Replace('\', '/')
}

function Get-PsaiIntArg {
    param($ToolArgs, [string]$Name, [int]$Default, [int]$Min, [int]$Max)
    $value = $ToolArgs[$Name]
    $number = $Default
    if ($null -ne $value -and ([string]$value) -ne '') {
        $parsed = 0
        if ([int]::TryParse(([string]$value), [ref]$parsed)) {
            $number = $parsed
        } else {
            try { $number = [int][double]$value } catch { }
        }
    }
    if ($Max -lt $Min) { $Max = $Min }
    if ($number -lt $Min) { $number = $Min }
    if ($number -gt $Max) { $number = $Max }
    return $number
}

function Test-PsaiReparsePoint {
    param([string]$Path)
    try {
        return (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch {
        return $true
    }
}

# Sorted folders (minus the skipped ones) and files of one folder, as @{ Path; Name; IsDir }.
function Get-PsaiDirEntries {
    param([string]$Dir)
    $list = New-Object System.Collections.Generic.List[object]
    $dirs = @()
    $files = @()
    try { $dirs = [System.IO.Directory]::GetDirectories($Dir) } catch { }
    try { $files = [System.IO.Directory]::GetFiles($Dir) } catch { }
    foreach ($d in @($dirs | Sort-Object)) {
        $name = [System.IO.Path]::GetFileName($d)
        if ($script:PsaiSkipDirs.Contains($name)) { continue }
        if (Test-PsaiReparsePoint $d) { continue }
        $list.Add(@{ Path = $d; Name = $name; IsDir = $true })
    }
    foreach ($f in @($files | Sort-Object)) {
        $list.Add(@{ Path = $f; Name = [System.IO.Path]::GetFileName($f); IsDir = $false })
    }
    return , $list.ToArray()
}

# The folder as an indented tree. Returns @{ Lines; Truncated }.
function Get-PsaiTree {
    param([string]$Start, [int]$Depth, [int]$Limit)
    $lines = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $children = Get-PsaiDirEntries -Dir $Start
    for ($i = $children.Count - 1; $i -ge 0; $i--) { $stack.Push(@($children[$i], 0)) }
    $truncated = $false
    while ($stack.Count -gt 0) {
        if ($lines.Count -ge $Limit) {
            $truncated = $true
            break
        }
        $item = $stack.Pop()
        $entry = $item[0]
        $level = [int]$item[1]
        $indent = '  ' * $level
        if ($entry.IsDir) {
            $lines.Add($indent + $entry.Name + '/')
            if (($level + 1) -lt $Depth) {
                $sub = Get-PsaiDirEntries -Dir $entry.Path
                for ($i = $sub.Count - 1; $i -ge 0; $i--) { $stack.Push(@($sub[$i], ($level + 1))) }
            }
        } else {
            $lines.Add($indent + $entry.Name)
        }
    }
    return @{ Lines = $lines; Truncated = $truncated }
}

# All text-like files under a folder (for search), skipping big and binary files.
function Get-PsaiFileList {
    param([string]$Start, [int]$Limit = 4000)
    $result = New-Object System.Collections.Generic.List[string]
    $queue = New-Object System.Collections.Generic.Queue[string]
    $queue.Enqueue($Start)
    $visited = 0
    while ($queue.Count -gt 0 -and $result.Count -lt $Limit -and $visited -lt 5000) {
        $dir = $queue.Dequeue()
        $visited++
        $files = @()
        $dirs = @()
        try { $files = [System.IO.Directory]::GetFiles($dir) } catch { }
        try { $dirs = [System.IO.Directory]::GetDirectories($dir) } catch { }
        foreach ($f in $files) {
            if ($script:PsaiBinaryExtensions.Contains([System.IO.Path]::GetExtension($f))) { continue }
            $size = 0
            try { $size = (New-Object System.IO.FileInfo($f)).Length } catch { continue }
            if ($size -gt 1MB) { continue }
            $result.Add($f)
            if ($result.Count -ge $Limit) { break }
        }
        foreach ($d in $dirs) {
            if ($script:PsaiSkipDirs.Contains([System.IO.Path]::GetFileName($d))) { continue }
            if (Test-PsaiReparsePoint $d) { continue }
            $queue.Enqueue($d)
        }
    }
    return , $result
}

# ----------------------------------------------------------------------- file helpers --

function Get-PsaiAnsiEncoding {
    try {
        return [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
    } catch {
        return [System.Text.Encoding]::GetEncoding(28591)
    }
}

# Reads a text file and remembers its encoding and line endings so edits keep them.
function Read-PsaiTextFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $encoding = $null
    $skip = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object System.Text.UTF8Encoding($true)
        $skip = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = New-Object System.Text.UnicodeEncoding($false, $true)
        $skip = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object System.Text.UnicodeEncoding($true, $true)
        $skip = 2
    }
    $text = ''
    if ($null -ne $encoding) {
        $text = $encoding.GetString($bytes, $skip, $bytes.Length - $skip)
    } else {
        try {
            $strict = New-Object System.Text.UTF8Encoding($false, $true)
            $text = $strict.GetString($bytes)
            $encoding = New-Object System.Text.UTF8Encoding($false)
        } catch {
            $encoding = Get-PsaiAnsiEncoding
            $text = $encoding.GetString($bytes)
        }
    }
    $eol = "`n"
    if ($text.Contains("`r`n")) { $eol = "`r`n" }
    return @{
        Text     = $text
        Encoding = $encoding
        Eol      = $eol
        Binary   = ($text.IndexOf([char]0) -ge 0)
    }
}

function Convert-PsaiEol {
    param([string]$Text, [string]$Eol)
    $t = $Text.Replace("`r`n", "`n")
    if ($Eol -eq "`r`n") { $t = $t.Replace("`n", "`r`n") }
    return $t
}

function Get-PsaiNewFileEol {
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    if (@('.bat', '.cmd') -contains $ext.ToLowerInvariant()) { return "`r`n" }
    return "`n"
}

# New files are UTF-8 without BOM, except PowerShell scripts with non-English characters:
# Windows PowerShell 5.1 only reads those correctly with a BOM.
function Get-PsaiNewFileEncoding {
    param([string]$Path, [string]$Text)
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if (@('.ps1', '.psm1', '.psd1') -contains $ext -and [regex]::IsMatch($Text, '[^\x00-\x7F]')) {
        return (New-Object System.Text.UTF8Encoding($true))
    }
    return (New-Object System.Text.UTF8Encoding($false))
}

function Write-PsaiTextFile {
    param([string]$Path, [string]$Text, $Encoding)
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    [System.IO.File]::WriteAllText($Path, $Text, $Encoding)
}

function Get-PsaiLineCount {
    param([string]$Text)
    if ($Text.Length -eq 0) { return 0 }
    $count = $Text.Split([char]10).Length
    if ($Text.EndsWith("`n", [StringComparison]::Ordinal)) { $count-- }
    return $count
}

# Finds old_text in the file. Exact match first; if that fails, a match that ignores
# spaces at the end of lines. Returns @{ Count; Index; Length }.
function Find-PsaiText {
    param([string]$Text, [string]$Find)
    $count = 0
    $first = -1
    $pos = 0
    while ($count -lt 10) {
        $i = $Text.IndexOf($Find, $pos, [StringComparison]::Ordinal)
        if ($i -lt 0) { break }
        $count++
        if ($first -lt 0) { $first = $i }
        $pos = $i + [Math]::Max(1, $Find.Length)
    }
    if ($count -gt 0) { return @{ Count = $count; Index = $first; Length = $Find.Length } }

    $lines = $Text.Split([char]10)
    $want = $Find.Split([char]10)
    $wantCount = $want.Length
    $endsWithNewline = $false
    if ($wantCount -gt 1 -and $want[$wantCount - 1] -eq '') {
        $wantCount--
        $endsWithNewline = $true
    }
    $matchCount = 0
    $matchLine = -1
    for ($i = 0; $i -le ($lines.Length - $wantCount); $i++) {
        $ok = $true
        for ($j = 0; $j -lt $wantCount; $j++) {
            if (-not [string]::Equals($lines[$i + $j].TrimEnd(), $want[$j].TrimEnd())) {
                $ok = $false
                break
            }
        }
        if ($ok) {
            $matchCount++
            if ($matchLine -lt 0) { $matchLine = $i }
            if ($matchCount -gt 1) { break }
        }
    }
    if ($matchCount -ne 1) { return @{ Count = $matchCount; Index = -1; Length = 0 } }
    $start = 0
    for ($k = 0; $k -lt $matchLine; $k++) { $start += $lines[$k].Length + 1 }
    $length = 0
    for ($k = 0; $k -lt $wantCount; $k++) { $length += $lines[$matchLine + $k].Length }
    $length += $wantCount - 1
    if ($endsWithNewline -and ($matchLine + $wantCount) -lt $lines.Length) { $length += 1 }
    return @{ Count = 1; Index = $start; Length = $length }
}

# ----------------------------------------------------------------------- VS Code bits --

function Find-PsaiEditorCommand {
    param([string]$Name)
    foreach ($candidate in @(($Name + '.cmd'), $Name)) {
        $cmd = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Path }
    }
    return $null
}

# VS Code is used for diffs when psai runs in VS Code's terminal (or DiffViewer is "vscode").
function Get-PsaiEditor {
    param($Config)
    $mode = ([string]$Config['DiffViewer']).ToLowerInvariant()
    if ($mode -eq 'terminal' -or $mode -eq 'off') { return $null }
    if ($mode -ne 'vscode' -and $env:TERM_PROGRAM -ne 'vscode') { return $null }
    $name = [string]$Config['EditorCommand']
    if (-not $name) { $name = 'code' }
    return (Find-PsaiEditorCommand $name)
}

function Open-PsaiEditorDiff {
    param($Session, [string]$FullPath, [string]$NewText, $Encoding)
    if (-not $Session.Editor) { return }
    try {
        $dir = [System.IO.Path]::Combine($Session.TempDir, [guid]::NewGuid().ToString('N').Substring(0, 8))
        $name = [System.IO.Path]::GetFileName($FullPath)
        $proposedDir = [System.IO.Path]::Combine($dir, 'proposed')
        [void][System.IO.Directory]::CreateDirectory($proposedDir)
        $right = [System.IO.Path]::Combine($proposedDir, $name)
        [System.IO.File]::WriteAllText($right, $NewText, $Encoding)
        $left = $FullPath
        if (-not [System.IO.File]::Exists($left)) {
            $emptyDir = [System.IO.Path]::Combine($dir, 'new file')
            [void][System.IO.Directory]::CreateDirectory($emptyDir)
            $left = [System.IO.Path]::Combine($emptyDir, $name)
            [System.IO.File]::WriteAllText($left, '')
        }
        & $Session.Editor --reuse-window --diff $left $right 2>&1 | Out-Null
        Write-PsaiNote 'Opened in VS Code: left is the file now, right is the proposed version.'
    } catch { }
}

function Open-PsaiEditorFile {
    param($Session, [string]$FullPath, [int]$Line)
    if (-not $Session.Editor -or -not $Session.Config['OpenEditedFiles']) { return }
    if ($Line -lt 1) { $Line = 1 }
    try { & $Session.Editor --reuse-window --goto ($FullPath + ':' + $Line) 2>&1 | Out-Null } catch { }
}

function Clear-PsaiTemp {
    param([string]$Dir)
    try {
        if (-not [System.IO.Directory]::Exists($Dir)) { return }
        $cutoff = (Get-Date).AddDays(-1)
        foreach ($sub in [System.IO.Directory]::GetDirectories($Dir)) {
            if ([System.IO.Directory]::GetLastWriteTime($sub) -lt $cutoff) {
                Remove-Item -LiteralPath $sub -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }
}

# ----------------------------------------------------------------------- approvals --

function Request-PsaiApproval {
    param($Session, [string]$Kind)
    if ($Kind -eq 'edit' -and $Session.AutoApproveEdits) {
        Write-PsaiNote '(applied: you said yes to all edits for this task)'
        return @{ Approved = $true; Feedback = '' }
    }
    if ($Kind -eq 'edit') {
        $choice = Read-PsaiChoice '  Apply this change? [y] yes  [n] no  [a] yes to all edits in this task  [s] stop: ' @('y', 'n', 'a', 's') ''
    } else {
        $choice = Read-PsaiChoice '  Run this command? [y] yes  [n] no  [s] stop: ' @('y', 'n', 's') ''
    }
    if ($choice -eq 'a') {
        $Session.AutoApproveEdits = $true
        return @{ Approved = $true; Feedback = '' }
    }
    if ($choice -eq 'y') { return @{ Approved = $true; Feedback = '' } }
    if ($choice -eq 's') {
        $Session.StopRequested = $true
        return @{ Approved = $false; Feedback = 'The user stopped the task.' }
    }
    $feedback = Read-PsaiLine '  What should psai do instead? (Enter to skip): ' 'DarkGray'
    return @{ Approved = $false; Feedback = $feedback }
}

function Get-PsaiRejectionText {
    param($Decision, [string]$What)
    $text = 'The user did not approve this ' + $What + '; nothing was changed.'
    if ($Decision.Feedback) {
        $text = $text + ' Their feedback: ' + $Decision.Feedback
    } else {
        $text = $text + ' Do not try the same thing again. Try another approach or ask the user what they want.'
    }
    return $text
}

# --------------------------------------------------------------------------- tools --

function Invoke-PsaiListFiles {
    param($Session, $ToolArgs)
    $start = Resolve-PsaiPath -Root $Session.Root -Path ([string]$ToolArgs['path'])
    if (-not [System.IO.Directory]::Exists($start)) {
        return ('Error: folder not found: ' + [string]$ToolArgs['path'] + '. Call list_files without a path to see the project folder.')
    }
    $depth = Get-PsaiIntArg -ToolArgs $ToolArgs -Name 'depth' -Default 3 -Min 1 -Max 6
    $tree = Get-PsaiTree -Start $start -Depth $depth -Limit 300
    $rel = Get-PsaiRelPath -Root $Session.Root -Full $start
    $header = 'Contents of ' + $rel + '/ (' + $depth + ' levels):'
    if ($rel -eq '.') { $header = 'Project folder (' + $depth + ' levels):' }
    if ($tree.Lines.Count -eq 0) { return ($header + "`n(empty folder)") }
    $text = $header + "`n" + ($tree.Lines -join "`n")
    if ($tree.Truncated) { $text = $text + "`n... (stopped at 300 entries; list a subfolder to see more)" }
    return $text
}

function Invoke-PsaiReadFile {
    param($Session, $ToolArgs)
    $rawPath = [string]$ToolArgs['path']
    if (-not $rawPath) { return 'Error: path is required.' }
    $full = Resolve-PsaiPath -Root $Session.Root -Path $rawPath
    $rel = Get-PsaiRelPath -Root $Session.Root -Full $full
    if ([System.IO.Directory]::Exists($full)) { return ('Error: ' + $rel + ' is a folder. Use list_files to see what is inside.') }
    if (-not [System.IO.File]::Exists($full)) { return ('Error: file not found: ' + $rel + '. Use list_files or search to find the right path.') }
    $size = (New-Object System.IO.FileInfo($full)).Length
    if ($size -gt 5MB) { return ('Error: ' + $rel + ' is too big to read (' + [Math]::Round($size / 1MB, 1) + ' MB).') }
    $file = Read-PsaiTextFile $full
    if ($file.Binary) { return ('Error: ' + $rel + ' is a binary file, not text.') }

    $lines = $file.Text.Replace("`r`n", "`n").Split([char]10)
    $total = $lines.Length
    if ($total -gt 0 -and $lines[$total - 1] -eq '') { $total-- }
    if ($total -eq 0) { return ('File: ' + $rel + ' (empty)') }

    $from = Get-PsaiIntArg -ToolArgs $ToolArgs -Name 'start_line' -Default 1 -Min 1 -Max $total
    $to = Get-PsaiIntArg -ToolArgs $ToolArgs -Name 'end_line' -Default $total -Min $from -Max $total
    $max = (Get-PsaiToolOutputLimit $Session.Config) - 300
    $builder = New-Object System.Text.StringBuilder
    $shownTo = $from - 1
    for ($n = $from; $n -le $to; $n++) {
        $lineText = $lines[$n - 1]
        if ($n -gt $from -and ($builder.Length + $lineText.Length + 1) -gt $max) { break }
        [void]$builder.Append($lineText).Append("`n")
        $shownTo = $n
    }
    $header = 'File: ' + $rel + ' (lines ' + $from + '-' + $shownTo + ' of ' + $total + ')'
    $text = $header + "`n" + $builder.ToString()
    if ($shownTo -lt $to) {
        $text = $text + '[Stopped at line ' + $shownTo + ' to save space. Call read_file with start_line=' + ($shownTo + 1) + ' to read more.]'
    }
    return $text
}

function Invoke-PsaiSearch {
    param($Session, $ToolArgs)
    $pattern = [string]$ToolArgs['pattern']
    if (-not $pattern) { return 'Error: pattern is required.' }
    $start = Resolve-PsaiPath -Root $Session.Root -Path ([string]$ToolArgs['path'])
    if ([System.IO.File]::Exists($start)) {
        $files = @($start)
    } elseif ([System.IO.Directory]::Exists($start)) {
        $files = Get-PsaiFileList -Start $start -Limit 4000
    } else {
        return ('Error: path not found: ' + [string]$ToolArgs['path'])
    }
    $options = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'
    $timeout = [TimeSpan]::FromSeconds(2)
    $regex = $null
    try {
        $regex = [System.Text.RegularExpressions.Regex]::new($pattern, $options, $timeout)
    } catch {
        $regex = [System.Text.RegularExpressions.Regex]::new([regex]::Escape($pattern), $options, $timeout)
    }
    $results = New-Object System.Collections.Generic.List[string]
    $max = 80
    foreach ($f in $files) {
        $content = $null
        try { $content = [System.IO.File]::ReadAllText($f) } catch { continue }
        if ($content.IndexOf([char]0) -ge 0) { continue }
        $hit = $false
        try { $hit = $regex.IsMatch($content) } catch { }
        if (-not $hit) { continue }
        $rel = Get-PsaiRelPath -Root $Session.Root -Full $f
        $fileLines = $content.Split([char]10)
        for ($n = 0; $n -lt $fileLines.Length; $n++) {
            $lineHit = $false
            try { $lineHit = $regex.IsMatch($fileLines[$n]) } catch { }
            if (-not $lineHit) { continue }
            $lineText = $fileLines[$n].Trim()
            if ($lineText.Length -gt 200) { $lineText = $lineText.Substring(0, 200) + '...' }
            $results.Add($rel + ':' + ($n + 1) + ': ' + $lineText)
            if ($results.Count -ge $max) { break }
        }
        if ($results.Count -ge $max) { break }
    }
    if ($results.Count -eq 0) { return ('No matches for "' + $pattern + '".') }
    $text = $results -join "`n"
    if ($results.Count -ge $max) { $text = $text + "`n... (stopped at " + $max + ' matches; search a smaller folder or a more exact pattern)' }
    return $text
}

function Write-PsaiChangeHeader {
    param([string]$Action, [string]$Target)
    Write-Host ''
    Write-Host ('  ' + $Action + ' ' + $Target) -ForegroundColor Yellow
}

function Invoke-PsaiWriteFile {
    param($Session, $ToolArgs)
    $rawPath = [string]$ToolArgs['path']
    if (-not $rawPath) { return 'Error: path is required.' }
    if ($null -eq $ToolArgs['content']) { return 'Error: content is required.' }
    $content = [string]$ToolArgs['content']
    $full = Resolve-PsaiPath -Root $Session.Root -Path $rawPath
    $rel = Get-PsaiRelPath -Root $Session.Root -Full $full
    if ([System.IO.Directory]::Exists($full)) { return ('Error: ' + $rel + ' is a folder.') }

    $line = 1
    if ([System.IO.File]::Exists($full)) {
        $old = Read-PsaiTextFile $full
        if ($old.Binary) { return ('Error: ' + $rel + ' is a binary file and cannot be changed with write_file.') }
        $newText = Convert-PsaiEol $content $old.Eol
        $encoding = $old.Encoding
        if ([string]::Equals($old.Text, $newText, [StringComparison]::Ordinal)) { return ('No change needed: ' + $rel + ' already has exactly this content.') }
        Write-PsaiChangeHeader 'Replace' $rel
        $line = Show-PsaiDiff -Old $old.Text -New $newText
    } else {
        $newText = Convert-PsaiEol $content (Get-PsaiNewFileEol $full)
        $encoding = Get-PsaiNewFileEncoding $full $newText
        Write-PsaiChangeHeader 'Create' $rel
        Show-PsaiNewFile $newText
    }
    Open-PsaiEditorDiff -Session $Session -FullPath $full -NewText $newText -Encoding $encoding
    $decision = Request-PsaiApproval -Session $Session -Kind 'edit'
    if (-not $decision.Approved) { return (Get-PsaiRejectionText $decision 'file change') }
    Write-PsaiTextFile -Path $full -Text $newText -Encoding $encoding
    Open-PsaiEditorFile -Session $Session -FullPath $full -Line $line
    return ('Saved ' + $rel + ' (' + (Get-PsaiLineCount $newText) + ' lines).')
}

function Invoke-PsaiEditFile {
    param($Session, $ToolArgs)
    $rawPath = [string]$ToolArgs['path']
    if (-not $rawPath) { return 'Error: path is required.' }
    $full = Resolve-PsaiPath -Root $Session.Root -Path $rawPath
    $rel = Get-PsaiRelPath -Root $Session.Root -Full $full
    if (-not [System.IO.File]::Exists($full)) { return ('Error: file not found: ' + $rel + '. To create a new file use write_file.') }
    $find = ([string]$ToolArgs['old_text']).Replace("`r`n", "`n")
    $replacement = ([string]$ToolArgs['new_text']).Replace("`r`n", "`n")
    if ($find.Length -eq 0) { return 'Error: old_text is empty. Copy the exact lines you want to replace from read_file output.' }

    $file = Read-PsaiTextFile $full
    if ($file.Binary) { return ('Error: ' + $rel + ' is a binary file, not text.') }
    $text = $file.Text.Replace("`r`n", "`n")
    $found = Find-PsaiText -Text $text -Find $find
    if ($found.Count -eq 0) {
        return ('Error: old_text was not found in ' + $rel + '. Call read_file again and copy the lines exactly, with the same spaces and indentation.')
    }
    if ($found.Count -gt 1) {
        return ('Error: old_text appears ' + $found.Count + ' times in ' + $rel + '. Include more of the surrounding lines so it matches only one place.')
    }
    $updated = $text.Substring(0, $found.Index) + $replacement + $text.Substring($found.Index + $found.Length)
    if ([string]::Equals($updated, $text, [StringComparison]::Ordinal)) { return 'No change needed: new_text is the same as old_text.' }
    $lineNumber = $text.Substring(0, $found.Index).Split([char]10).Length

    Write-PsaiChangeHeader 'Edit' ($rel + ' (line ' + $lineNumber + ')')
    [void](Show-PsaiDiff -Old $text -New $updated)
    $final = Convert-PsaiEol $updated $file.Eol
    Open-PsaiEditorDiff -Session $Session -FullPath $full -NewText $final -Encoding $file.Encoding
    $decision = Request-PsaiApproval -Session $Session -Kind 'edit'
    if (-not $decision.Approved) { return (Get-PsaiRejectionText $decision 'edit') }
    Write-PsaiTextFile -Path $full -Text $final -Encoding $file.Encoding
    Open-PsaiEditorFile -Session $Session -FullPath $full -Line $lineNumber
    return ('Edited ' + $rel + ' at line ' + $lineNumber + '.')
}

function Stop-PsaiProcessTree {
    param($Process)
    try {
        if ($env:OS -eq 'Windows_NT') {
            & taskkill.exe /PID $Process.Id /T /F 2>&1 | Out-Null
        } else {
            $Process.Kill()
        }
    } catch {
        try { $Process.Kill() } catch { }
    }
}

# PowerShell sometimes reports errors from a child process in an XML format ("CLIXML").
function ConvertFrom-PsaiClixml {
    param([string]$Text)
    if (-not $Text -or $Text.IndexOf('#< CLIXML', [StringComparison]::Ordinal) -lt 0) { return $Text }
    $builder = New-Object System.Text.StringBuilder
    foreach ($m in [regex]::Matches($Text, '<S S="[^"]*">(.*?)</S>')) {
        $value = $m.Groups[1].Value.Replace('_x000D__x000A_', "`n").Replace('_x000A_', "`n").Replace('_x000D_', '')
        [void]$builder.Append([System.Net.WebUtility]::HtmlDecode($value))
    }
    return $builder.ToString()
}

function ConvertTo-PsaiPsLiteral {
    param([string]$Text)
    return ("'" + $Text.Replace("'", "''") + "'")
}

# Runs a command in a separate, non-interactive PowerShell process and captures all output.
function Invoke-PsaiChildPowerShell {
    param([string]$Command, [string]$WorkingDirectory, [int]$TimeoutSec)
    if ($TimeoutSec -le 0) { $TimeoutSec = 120 }
    $exe = $null
    try { $exe = (Get-Process -Id $PID).Path } catch { }
    if (-not $exe) {
        if ($PSVersionTable.PSEdition -eq 'Core') { $exe = 'pwsh' } else { $exe = 'powershell.exe' }
    }
    $outFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'psai-output-' + [guid]::NewGuid().ToString('N') + '.txt')
    $wrapper = @(
        '$ProgressPreference = ''SilentlyContinue''',
        'try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }',
        ('Set-Location -LiteralPath ' + (ConvertTo-PsaiPsLiteral $WorkingDirectory)),
        '$global:LASTEXITCODE = 0',
        '& {',
        $Command,
        ('} *>&1 | Out-File -FilePath ' + (ConvertTo-PsaiPsLiteral $outFile) + ' -Encoding utf8 -Width 300'),
        'exit $global:LASTEXITCODE'
    ) -join "`n"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapper))
    if ($encoded.Length -gt 30000) {
        return @{ ExitCode = -1; Output = 'Error: the command is too long. Write it to a .ps1 file with write_file and run that file instead.'; Stopped = '' }
    }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + $encoded
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = $WorkingDirectory

    $process = [System.Diagnostics.Process]::Start($info)
    try { $process.StandardInput.Close() } catch { }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $stopped = ''
    $spinner = New-PsaiSpinner 'running'
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    Enter-PsaiKeyCapture
    try {
        while (-not $process.WaitForExit(100)) {
            Update-PsaiSpinner $spinner
            if (Test-PsaiCancelKey) {
                $stopped = 'You stopped the command.'
                break
            }
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSec) {
                $stopped = 'The command was stopped after ' + $TimeoutSec + ' seconds (time limit).'
                break
            }
        }
        if ($stopped) { Stop-PsaiProcessTree $process }
        [void]$process.WaitForExit(5000)
    } finally {
        Exit-PsaiKeyCapture
        Stop-PsaiSpinner $spinner
    }

    $parts = New-Object System.Collections.Generic.List[string]
    try {
        if ([System.IO.File]::Exists($outFile)) {
            $parts.Add([System.IO.File]::ReadAllText($outFile))
            Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    try { if ($stdoutTask.Wait(2000)) { $parts.Add([string]$stdoutTask.Result) } } catch { }
    try { if ($stderrTask.Wait(2000)) { $parts.Add((ConvertFrom-PsaiClixml ([string]$stderrTask.Result))) } } catch { }
    $output = (@($parts | Where-Object { $_ -and $_.Trim() }) -join "`n").TrimEnd()
    $exitCode = -1
    try { if ($process.HasExited) { $exitCode = $process.ExitCode } } catch { }
    return @{ ExitCode = $exitCode; Output = $output; Stopped = $stopped }
}

function Invoke-PsaiRunCommand {
    param($Session, $ToolArgs)
    $command = [string]$ToolArgs['command']
    if (-not $command.Trim()) { return 'Error: command is empty.' }
    Write-Host ''
    Write-Host '  Run command:' -ForegroundColor Yellow
    foreach ($commandLine in $command.Replace("`r`n", "`n").Split([char]10)) { Write-Host ('    ' + $commandLine) -ForegroundColor White }
    if (Test-PsaiRisky $command) { Write-Host '  Careful: this command can delete or change things on your computer.' -ForegroundColor Red }
    $decision = Request-PsaiApproval -Session $Session -Kind 'command'
    if (-not $decision.Approved) { return (Get-PsaiRejectionText $decision 'command') }

    $run = Invoke-PsaiChildPowerShell -Command $command -WorkingDirectory $Session.Root -TimeoutSec ([int]$Session.Config['CommandTimeoutSec'])
    $outputLines = @()
    if ($run.Output) { $outputLines = $run.Output.Replace("`r`n", "`n").Split([char]10) }
    $shown = [Math]::Min($outputLines.Length, 25)
    for ($n = 0; $n -lt $shown; $n++) { Write-Host ('    ' + $outputLines[$n]) -ForegroundColor DarkGray }
    if ($outputLines.Length -gt $shown) { Write-PsaiNote ('  ... ' + ($outputLines.Length - $shown) + ' more lines (the model sees them)') }
    if ($outputLines.Length -eq 0) { Write-PsaiNote '(no output)' }
    $status = 'Exit code: ' + $run.ExitCode
    if ($run.Stopped) {
        Write-PsaiNote $run.Stopped
        $status = $status + '. ' + $run.Stopped
    } else {
        Write-PsaiNote ('(exit code ' + $run.ExitCode + ')')
    }
    $output = $run.Output
    if (-not $output) { $output = '(no output)' }
    return ($status + "`n" + $output)
}

function Invoke-PsaiTool {
    param($Session, $Call)
    if ($Call.error) { return ('Error: ' + $Call.error) }
    $toolArgs = $Call.arguments
    if ($null -eq $toolArgs) { $toolArgs = New-PsaiMap }
    $name = ([string]$Call.name).ToLowerInvariant()
    try {
        if ($name -eq 'list_files') { return (Invoke-PsaiListFiles -Session $Session -ToolArgs $toolArgs) }
        if ($name -eq 'read_file') { return (Invoke-PsaiReadFile -Session $Session -ToolArgs $toolArgs) }
        if ($name -eq 'search') { return (Invoke-PsaiSearch -Session $Session -ToolArgs $toolArgs) }
        if ($name -eq 'write_file') { return (Invoke-PsaiWriteFile -Session $Session -ToolArgs $toolArgs) }
        if ($name -eq 'edit_file') { return (Invoke-PsaiEditFile -Session $Session -ToolArgs $toolArgs) }
        if ($name -eq 'run_command') { return (Invoke-PsaiRunCommand -Session $Session -ToolArgs $toolArgs) }
        return ('Error: there is no tool called "' + $Call.name + '". Available tools: ' + ($Session.ToolNames -join ', ') + '.')
    } catch {
        return ('Error: ' + $_.Exception.Message)
    }
}

function Write-PsaiToolActivity {
    param($Call)
    $toolArgs = $Call.arguments
    if ($null -eq $toolArgs) { $toolArgs = New-PsaiMap }
    $name = [string]$Call.name
    $text = $null
    if ($name -eq 'list_files') {
        $p = [string]$toolArgs['path']
        if (-not $p) { $p = '.' }
        $text = 'list_files ' + $p
    } elseif ($name -eq 'read_file') {
        $text = 'read_file ' + [string]$toolArgs['path']
        if ($toolArgs['start_line']) { $text = $text + ' (from line ' + [string]$toolArgs['start_line'] + ')' }
    } elseif ($name -eq 'search') {
        $text = 'search "' + [string]$toolArgs['pattern'] + '"'
        if ($toolArgs['path']) { $text = $text + ' in ' + [string]$toolArgs['path'] }
    }
    if ($text) { Write-Host ('  > ' + $text) -ForegroundColor DarkGray }
}

# ------------------------------------------------------------------------ agent loop --

function Invoke-PsaiAgentTurn {
    param($Session)
    $config = $Session.Config
    $maxSteps = [int]$config['MaxAgentSteps']
    if ($maxSteps -le 0) { $maxSteps = 30 }
    $steps = 0
    while ($true) {
        if ($steps -ge $maxSteps) {
            Write-Host ''
            $more = Read-PsaiChoice ('  psai has taken ' + $steps + ' steps on this task. Keep going? [y/n]: ') @('y', 'n') ''
            if ($more -ne 'y') { return }
            $steps = 0
        }
        $steps++

        $tools = $null
        $extra = 0
        if (-not $Session.TextMode) {
            $tools = $Session.Tools
            $extra = $Session.ToolsChars
        }
        Limit-PsaiHistory -Messages $Session.Messages -Config $config -ExtraChars $extra
        Write-Host ''
        $res = $null
        try {
            $res = Invoke-PsaiModel -Config $config -Messages $Session.Messages -Tools $tools
        } catch {
            $message = $_.Exception.Message
            if (-not $Session.TextMode -and (Test-PsaiText $message 'does not support tools')) {
                Write-PsaiNote 'This model has no built-in tool support, so psai will describe the tools to it in text.'
                Enable-PsaiTextToolMode $Session
                $steps--
                continue
            }
            Write-PsaiError $message
            return
        }

        if ($res.cancelled) {
            if ($res.content) { $Session.Messages.Add(@{ role = 'assistant'; content = $res.content }) }
            Write-PsaiNote '(stopped)'
            return
        }

        $calls = $res.tool_calls
        $fromText = $false
        if ($calls.Count -eq 0 -and $res.content) {
            $parsed = Get-PsaiTextToolCalls -Text $res.content -KnownNames $Session.ToolNames
            if ($parsed.Count -gt 0) {
                $calls = $parsed
                $fromText = $true
            }
        }

        $assistant = @{ role = 'assistant'; content = [string]$res.content }
        if ($calls.Count -gt 0 -and -not $fromText) { $assistant['tool_calls'] = $calls.ToArray() }
        if ($res.content -or $calls.Count -gt 0) { $Session.Messages.Add($assistant) }

        if ($calls.Count -eq 0) {
            if (-not $res.content) { Write-PsaiNote '(the model gave an empty answer; try describing the task differently)' }
            return
        }

        foreach ($call in $calls) {
            if ($Session.StopRequested) {
                $out = 'Skipped: the user stopped the task.'
            } else {
                Write-PsaiToolActivity $call
                $out = Invoke-PsaiTool -Session $Session -Call $call
            }
            $out = Limit-PsaiText -Text ([string]$out) -Max (Get-PsaiToolOutputLimit $config)
            if ($fromText) {
                $Session.Messages.Add(@{ role = 'user'; content = ('Result of ' + $call.name + ":`n" + $out) })
            } else {
                $Session.Messages.Add(@{ role = 'tool'; content = $out; tool_call_id = $call.id; name = $call.name })
            }
            if (-not $Session.StopRequested -and $out.StartsWith('Error:', [StringComparison]::Ordinal)) {
                Write-PsaiNote ('  ' + $out.Split([char]10)[0])
            }
        }
        if ($Session.StopRequested) {
            Write-PsaiNote '(task stopped; type a new message to go on)'
            return
        }
    }
}

function Start-PsaiAgent {
    param($Config, [string]$FirstTask)
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') {
        Write-PsaiError 'psai /code works in a normal folder. Use cd to go to your project folder first.'
        return
    }
    $current = $location.ProviderPath
    if ([System.IO.Path]::GetPathRoot($current) -eq $current) {
        Write-PsaiError 'psai /code should run inside a project folder, not at the top of a drive. Use cd to go to your project first.'
        return
    }
    $root = $current.TrimEnd('/', '\')
    $tempDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'psai')
    Clear-PsaiTemp $tempDir

    $session = @{
        Config           = $Config
        Root             = $root
        Messages         = (New-Object System.Collections.Generic.List[object])
        Tools            = (Get-PsaiToolDefinitions)
        ToolsChars       = 0
        ToolNames        = @('list_files', 'read_file', 'search', 'write_file', 'edit_file', 'run_command')
        TextMode         = $false
        AutoApproveEdits = $false
        StopRequested    = $false
        Editor           = (Get-PsaiEditor -Config $Config)
        TempDir          = $tempDir
        Overview         = ''
    }
    $session.ToolsChars = (ConvertTo-PsaiJson $session.Tools).Length
    $tree = Get-PsaiTree -Start $root -Depth 2 -Limit 80
    if ($tree.Lines.Count -eq 0) {
        $session.Overview = '(the folder is empty)'
    } else {
        $session.Overview = $tree.Lines -join "`n"
        if ($tree.Truncated) { $session.Overview = $session.Overview + "`n... (more files not shown)" }
    }
    $session.Messages.Add(@{ role = 'system'; content = (Get-PsaiAgentPrompt $session) })

    Write-Host ''
    Write-Host ('  psai code - ' + $Config['Model'] + ' on ' + (Get-PsaiProviderName $Config)) -ForegroundColor Cyan
    Write-Host ('  Project: ' + $root) -ForegroundColor Cyan
    Write-PsaiNote 'Describe a task. psai asks before every file change and every command.'
    Write-PsaiNote 'Esc stops the model. /help for commands, /exit to leave.'
    if ($session.Editor) { Write-PsaiNote 'Proposed changes also open as diffs in VS Code.' }

    $pending = [string]$FirstTask
    while ($true) {
        if ($pending) {
            $line = $pending
            $pending = ''
            Write-Host ''
            Write-Host ('code> ' + $line) -ForegroundColor Magenta
        } else {
            $line = Read-PsaiInput -Label 'code' -Color 'Magenta'
        }
        if ($null -eq $line) { break }
        $text = $line.Trim()
        if ($text -eq '') { continue }
        $lower = $text.ToLowerInvariant()
        if ($lower -eq '/exit' -or $lower -eq '/quit' -or $lower -eq '/q' -or $lower -eq 'exit' -or $lower -eq 'quit') { break }
        if ($lower -eq '/clear') {
            while ($session.Messages.Count -gt 1) { $session.Messages.RemoveAt(1) }
            Write-PsaiNote 'Started fresh. psai forgot the conversation; your files are unchanged.'
            continue
        }
        if ($lower -eq '/help') {
            Show-PsaiReplHelp -Agent
            continue
        }
        if ($lower -eq '/model') {
            if (Update-PsaiModelChoice -Config $Config) {
                $session.TextMode = $false
                $session.Messages[0] = @{ role = 'system'; content = (Get-PsaiAgentPrompt $session) }
            }
            continue
        }
        if ($lower.StartsWith('/', [StringComparison]::Ordinal) -and $lower.IndexOf(' ') -lt 0) {
            Write-PsaiNote ('Unknown command ' + $text + '. Type /help to see the commands.')
            continue
        }
        $session.AutoApproveEdits = $false
        $session.StopRequested = $false
        $session.Messages.Add(@{ role = 'user'; content = $text; task = $true })
        Invoke-PsaiAgentTurn -Session $session
    }
}
