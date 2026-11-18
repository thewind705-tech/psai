# Settings (~\.psai\config.json) and the first-run setup.

$script:PsaiRecommendedModel = 'qwen3.5:9b'
$script:PsaiConfigKeys = @(
    'Provider', 'Url', 'Model', 'ApiKey', 'ContextLength', 'Temperature', 'Think', 'ShowThinking',
    'DiffViewer', 'EditorCommand', 'OpenEditedFiles', 'CommandTimeoutSec', 'RequestTimeoutSec',
    'MaxToolOutputChars', 'MaxAgentSteps'
)

function Get-PsaiConfigPath {
    return [System.IO.Path]::Combine($HOME, '.psai', 'config.json')
}

function New-PsaiDefaultConfig {
    $config = New-PsaiMap
    $config['Provider'] = ''
    $config['Url'] = ''
    $config['Model'] = ''
    $config['ApiKey'] = ''
    $config['ContextLength'] = 16384
    $config['Temperature'] = $null
    $config['Think'] = $null
    $config['ShowThinking'] = $false
    $config['DiffViewer'] = 'auto'
    $config['EditorCommand'] = 'code'
    $config['OpenEditedFiles'] = $true
    $config['CommandTimeoutSec'] = 120
    $config['RequestTimeoutSec'] = 300
    $config['MaxToolOutputChars'] = 12000
    $config['MaxAgentSteps'] = 30
    return $config
}

# Returns the saved settings, or $null when psai has not been set up yet.
function Read-PsaiConfigFile {
    $path = Get-PsaiConfigPath
    if (-not [System.IO.File]::Exists($path)) { return $null }
    $parsed = ConvertFrom-PsaiJsonSafe ([System.IO.File]::ReadAllText($path))
    if ($null -eq $parsed) {
        throw ("The settings file is not valid JSON: " + $path + ". Fix it with 'psai /config' or start over with 'psai /setup'.")
    }
    $config = New-PsaiDefaultConfig
    foreach ($prop in $parsed.PSObject.Properties) { $config[$prop.Name] = $prop.Value }
    if (-not $config['Provider'] -or -not $config['Url'] -or -not $config['Model']) { return $null }
    $config['Provider'] = ([string]$config['Provider']).ToLowerInvariant()
    return $config
}

function Save-PsaiConfig {
    param($Config)
    $path = Get-PsaiConfigPath
    $dir = [System.IO.Path]::GetDirectoryName($path)
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $ordered = [ordered]@{}
    foreach ($key in $script:PsaiConfigKeys) { $ordered[$key] = $Config[$key] }
    $json = ConvertTo-PsaiJson $ordered -Pretty
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# Loads the settings, running the setup first if there are none yet.
function Get-PsaiConfigOrSetup {
    $config = Read-PsaiConfigFile
    if ($config) { return $config }
    Write-Host ''
    Write-Host '  Welcome to psai! First, let''s connect it to your local AI app.' -ForegroundColor Cyan
    return (Invoke-PsaiSetup -Existing $null)
}

# Your own instructions for the model, from text files in ~\.psai:
#   prompt.md   used in every mode
#   command.md  one-shot commands (psai "...")
#   chat.md     chat (psai)
#   code.md     coding agent (psai /code)
#   explain.md  psai /explain
function Get-PsaiCustomPrompt {
    param([string]$Mode)
    $dir = [System.IO.Path]::Combine($HOME, '.psai')
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('prompt.md', ($Mode + '.md'))) {
        $path = [System.IO.Path]::Combine($dir, $name)
        if (-not [System.IO.File]::Exists($path)) { continue }
        $text = ''
        try { $text = ([System.IO.File]::ReadAllText($path)).Trim() } catch { }
        if ($text) { $parts.Add($text) }
    }
    if ($parts.Count -eq 0) { return '' }
    return ("`n`nThe user's own instructions (follow them):`n" + ($parts -join "`n`n"))
}

function Get-PsaiProviderName {
    param($Config)
    if ($Config['Provider'] -eq 'ollama') { return 'Ollama' }
    return 'LM Studio'
}

function Format-PsaiUrl {
    param([string]$Url)
    $u = $Url.Trim().TrimEnd('/')
    if (-not (Test-PsaiMatch $u '^[a-z][a-z0-9+.-]*://')) { $u = 'http://' + $u }
    foreach ($suffix in @('/v1', '/api')) {
        if ($u.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) { $u = $u.Substring(0, $u.Length - $suffix.Length) }
    }
    return $u.TrimEnd('/')
}

# Lists the models on the server as @{ Name; Info } entries.
function Get-PsaiModels {
    param($Config)
    $base = ([string]$Config['Url']).TrimEnd('/')
    $list = New-Object System.Collections.Generic.List[object]
    if ($Config['Provider'] -eq 'ollama') {
        $parsed = ConvertFrom-PsaiJsonSafe (Invoke-PsaiHttp -Url ($base + '/api/tags') -ApiKey $Config['ApiKey'] -TimeoutSec 10)
        if ($null -eq $parsed) { throw ('The server at ' + $base + " doesn't look like Ollama.") }
        foreach ($model in @($parsed.models)) {
            if ($null -eq $model) { continue }
            $info = New-Object System.Collections.Generic.List[string]
            if ($model.size) { $info.Add(('{0:N1} GB' -f ([double]$model.size / 1GB))) }
            if ($model.details -and $model.details.quantization_level) { $info.Add([string]$model.details.quantization_level) }
            $list.Add(@{ Name = [string]$model.name; Info = ($info -join ', ') })
        }
    } else {
        $parsed = ConvertFrom-PsaiJsonSafe (Invoke-PsaiHttp -Url ($base + '/v1/models') -ApiKey $Config['ApiKey'] -TimeoutSec 10)
        if ($null -eq $parsed) { throw ('The server at ' + $base + " doesn't look like LM Studio.") }
        foreach ($model in @($parsed.data)) {
            if ($null -eq $model) { continue }
            $id = [string]$model.id
            if (-not $id -or (Test-PsaiText $id 'embed')) { continue }
            $list.Add(@{ Name = $id; Info = '' })
        }
    }
    return , $list.ToArray()
}

function Test-PsaiSameModel {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    if ($A.IndexOf(':') -lt 0) { $A = $A + ':latest' }
    if ($B.IndexOf(':') -lt 0) { $B = $B + ':latest' }
    return [string]::Equals($A, $B, [StringComparison]::OrdinalIgnoreCase)
}

function Test-PsaiModelInList {
    param([string]$Name, $Names)
    foreach ($n in $Names) {
        if (Test-PsaiSameModel $Name ([string]$n)) { return $true }
    }
    return $false
}

function Test-PsaiRecommended {
    param([string]$Name)
    return ((Test-PsaiText $Name 'qwen3.5') -and (Test-PsaiText $Name '9b'))
}

# Shows the numbered model list and returns the chosen model name.
function Select-PsaiModel {
    param($Config, $Models)
    Write-Host ''
    Write-Host '  Models on this server:'
    for ($i = 0; $i -lt $Models.Count; $i++) {
        $model = $Models[$i]
        $label = '    [' + ($i + 1) + '] ' + $model.Name
        if ($model.Info) { $label = $label + '  (' + $model.Info + ')' }
        Write-Host -NoNewline $label
        if (Test-PsaiRecommended $model.Name) { Write-Host -NoNewline '  recommended' -ForegroundColor Green }
        if ($Config['Model'] -and (Test-PsaiSameModel $model.Name $Config['Model'])) { Write-Host -NoNewline '  current' -ForegroundColor Cyan }
        Write-Host ''
    }
    $hint = '  Choose a number (or type a model name): '
    if ($Config['Model']) { $hint = '  Choose a number (Enter keeps ' + $Config['Model'] + '): ' }
    while ($true) {
        $answer = Read-PsaiLine $hint 'Yellow'
        if ($answer -eq '') {
            if ($Config['Model']) { return [string]$Config['Model'] }
            continue
        }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number)) {
            if ($number -ge 1 -and $number -le $Models.Count) { return [string]$Models[$number - 1].Name }
            Write-PsaiNote ('Pick a number from 1 to ' + $Models.Count + '.')
            continue
        }
        return $answer
    }
}

function Write-PsaiServerTip {
    param([string]$Provider)
    if ($Provider -eq 'ollama') {
        Write-PsaiNote 'Make sure Ollama is running: look for its icon next to the clock, or run "ollama serve" in another window.'
    } else {
        Write-PsaiNote 'In LM Studio, open the Developer tab and switch the server on (Status: Running).'
    }
}

function Invoke-PsaiSetup {
    param($Existing)
    $config = New-PsaiDefaultConfig
    if ($Existing) {
        foreach ($key in @($Existing.Keys)) { $config[[string]$key] = $Existing[$key] }
    }

    Write-Host ''
    Write-Host '  psai setup' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Which app runs your AI models?'
    Write-Host '    [1] Ollama'
    Write-Host '    [2] LM Studio'
    $pick = Read-PsaiChoice '  Choose 1 or 2: ' @('1', '2') ''
    $oldProvider = [string]$config['Provider']
    if ($pick -eq '1') {
        $config['Provider'] = 'ollama'
        $defaultUrl = 'http://localhost:11434'
    } else {
        $config['Provider'] = 'lmstudio'
        $defaultUrl = 'http://localhost:1234'
    }
    if ($oldProvider -eq $config['Provider'] -and $config['Url']) { $defaultUrl = [string]$config['Url'] }

    # Server address
    $models = $null
    while ($null -eq $models) {
        Write-Host ''
        $answer = Read-PsaiLine ('  Server URL (press Enter for ' + $defaultUrl + '): ') 'Yellow'
        if ($answer -eq '') { $answer = $defaultUrl }
        $config['Url'] = Format-PsaiUrl $answer
        Write-Host -NoNewline ('  Checking ' + $config['Url'] + ' ... ')
        try {
            $models = Get-PsaiModels -Config $config
            Write-Host 'connected.' -ForegroundColor Green
        } catch {
            Write-Host 'no answer.' -ForegroundColor Red
            Write-PsaiNote $_.Exception.Message
            Write-PsaiServerTip -Provider $config['Provider']
            $next = Read-PsaiChoice '  [r] try again  [q] quit setup: ' @('r', 'q') 'r'
            if ($next -eq 'q') { return $null }
            $defaultUrl = [string]$config['Url']
            $models = $null
        }
    }

    # Model
    while ($models.Count -eq 0) {
        Write-Host ''
        Write-Host '  There are no models on this server yet.' -ForegroundColor Yellow
        if ($config['Provider'] -eq 'ollama') {
            Write-Host ('  Download the recommended one in another window:  ollama pull ' + $script:PsaiRecommendedModel)
        } else {
            Write-Host '  Download one in LM Studio: search for "qwen3.5 9b" and pick a Q4_K_M file.'
        }
        $next = Read-PsaiChoice '  [r] check again  [t] type a model name  [q] quit setup: ' @('r', 't', 'q') 'r'
        if ($next -eq 'q') { return $null }
        if ($next -eq 't') { break }
        try { $models = Get-PsaiModels -Config $config } catch { Write-PsaiError $_.Exception.Message }
    }
    if ($models.Count -gt 0) {
        $config['Model'] = Select-PsaiModel -Config $config -Models $models
    } else {
        $name = ''
        while ($name -eq '') { $name = Read-PsaiLine '  Model name: ' 'Yellow' }
        $config['Model'] = $name
    }
    if ($config['Provider'] -eq 'ollama') {
        $names = @($models | ForEach-Object { $_.Name })
        if (-not (Test-PsaiModelInList $config['Model'] $names)) {
            Write-Host ('  Note: ' + $config['Model'] + ' is not downloaded yet. Run:  ollama pull ' + $config['Model']) -ForegroundColor Yellow
        }
    }

    # Context size (LM Studio decides it when it loads the model, so ask)
    if ($config['Provider'] -eq 'lmstudio') {
        Write-Host ''
        Write-PsaiNote 'LM Studio sets the context length (how much text the model can keep in mind) when it loads a model.'
        Write-PsaiNote 'Use at least 8192 for chat and 16384 for /code if your GPU has room.'
        $ctxAnswer = Read-PsaiLine '  Context length you load the model with (Enter for 8192): ' 'Yellow'
        $ctx = 0
        if ([int]::TryParse($ctxAnswer, [ref]$ctx) -and $ctx -ge 1024) { $config['ContextLength'] = $ctx }
        else { $config['ContextLength'] = 8192 }
    }

    Save-PsaiConfig $config
    Write-Host ''
    Write-Host ('  Saved: ' + $config['Model'] + ' on ' + (Get-PsaiProviderName $config) + ' at ' + $config['Url']) -ForegroundColor Green
    Write-PsaiNote ('Settings file: ' + (Get-PsaiConfigPath))

    if ($config['Provider'] -eq 'ollama') { Test-PsaiSetupGpu -Config $config }
    Show-PsaiQuickStart
    return $config
}

function Show-PsaiQuickStart {
    Write-Host ''
    Write-Host '  Ready. Try:' -ForegroundColor Cyan
    Write-Host '    psai "show the 10 biggest files in this folder"'
    Write-Host '    psai                 chat'
    Write-Host '    psai /code           coding agent in the current folder'
    Write-Host '    psai /help           everything else'
}

# Loads the model once in Ollama and checks how much of it is in GPU memory.
# Returns @{ Percent } or $null when Ollama does not report it.
function Get-PsaiGpuFit {
    param($Config, [switch]$Load)
    $base = ([string]$Config['Url']).TrimEnd('/')
    if ($Load) {
        $body = ConvertTo-PsaiJson ([ordered]@{
                model    = [string]$Config['Model']
                messages = @(@{ role = 'user'; content = 'Hi' })
                stream   = $false
                options  = [ordered]@{ num_ctx = [int]$Config['ContextLength']; num_predict = 1 }
            })
        [void](Invoke-PsaiHttp -Method 'POST' -Url ($base + '/api/chat') -Body $body -ApiKey $Config['ApiKey'] -TimeoutSec 600 -SpinnerText ('loading ' + $Config['Model']))
    }
    $parsed = ConvertFrom-PsaiJsonSafe (Invoke-PsaiHttp -Url ($base + '/api/ps') -ApiKey $Config['ApiKey'] -TimeoutSec 10)
    if ($null -eq $parsed) { return $null }
    foreach ($model in @($parsed.models)) {
        if ($null -eq $model) { continue }
        if ((Test-PsaiSameModel ([string]$model.name) $Config['Model']) -or (Test-PsaiSameModel ([string]$model.model) $Config['Model'])) {
            $size = [double]$model.size
            $vram = [double]$model.size_vram
            if ($size -le 0) { return $null }
            return @{ Percent = [int][Math]::Floor(100 * $vram / $size) }
        }
    }
    return $null
}

function Test-PsaiSetupGpu {
    param($Config)
    Write-Host ''
    $go = Read-PsaiChoice '  Check that the model fits in your GPU memory? This loads it once. [Y/n]: ' @('y', 'n') 'y'
    if ($go -ne 'y') { return }
    while ($true) {
        $fit = $null
        try {
            $fit = Get-PsaiGpuFit -Config $Config -Load
        } catch [System.OperationCanceledException] {
            Write-PsaiNote 'Skipped.'
            return
        } catch {
            Write-PsaiError $_.Exception.Message
            return
        }
        $ctx = [int]$Config['ContextLength']
        if ($null -eq $fit) {
            Write-PsaiNote 'Ollama did not report GPU use for this model.'
            return
        }
        if ($fit.Percent -ge 100) {
            Write-Host ('  The model fits fully in GPU memory with a ' + $ctx + '-token context.') -ForegroundColor Green
            return
        }
        if ($fit.Percent -le 0) {
            Write-Host '  The model runs on the CPU only. It works, but slowly. If you have an NVIDIA or AMD GPU, update its driver and restart Ollama.' -ForegroundColor Yellow
            return
        }
        Write-Host ('  Only ' + $fit.Percent + '% of the model is in GPU memory. The rest runs on the CPU, which is much slower.') -ForegroundColor Yellow
        $smaller = [int][Math]::Floor($ctx / 2)
        if ($smaller -lt 4096) {
            Write-Host '  Try a smaller model or a smaller quantization (for example Q4_K_M instead of Q8_0).' -ForegroundColor Yellow
            return
        }
        $again = Read-PsaiChoice ('  Lower the context from ' + $ctx + ' to ' + $smaller + ' tokens and test again? [Y/n]: ') @('y', 'n') 'y'
        if ($again -ne 'y') { return }
        $Config['ContextLength'] = $smaller
        Save-PsaiConfig $Config
    }
}

function Show-PsaiStatus {
    $config = Read-PsaiConfigFile
    if (-not $config) {
        Write-PsaiNote 'psai is not set up yet. Run: psai /setup'
        return
    }
    Write-Host ''
    Write-Host ('  App:       ' + (Get-PsaiProviderName $config) + '  ' + $config['Url'])
    Write-Host ('  Model:     ' + $config['Model'])
    Write-Host ('  Context:   ' + $config['ContextLength'] + ' tokens')
    Write-Host ('  Settings:  ' + (Get-PsaiConfigPath))
    Write-Host -NoNewline '  Server:    '
    $models = $null
    try {
        $models = Get-PsaiModels -Config $config
    } catch {
        Write-Host 'not reachable' -ForegroundColor Red
        Write-PsaiNote $_.Exception.Message
        Write-PsaiServerTip -Provider $config['Provider']
        return
    }
    Write-Host ('connected (' + $models.Count + ' models)') -ForegroundColor Green
    $names = @($models | ForEach-Object { $_.Name })
    if (-not (Test-PsaiModelInList $config['Model'] $names)) {
        Write-Host ('  Warning:   ' + $config['Model'] + ' is not on the server. Run psai /model to pick another.') -ForegroundColor Yellow
    }
    if ($config['Provider'] -eq 'ollama') {
        Write-Host -NoNewline '  GPU:       '
        $fit = $null
        try { $fit = Get-PsaiGpuFit -Config $config } catch { }
        if ($null -eq $fit) {
            Write-Host 'model not loaded right now' -ForegroundColor DarkGray
        } elseif ($fit.Percent -ge 100) {
            Write-Host 'the whole model is in GPU memory' -ForegroundColor Green
        } else {
            Write-Host ([string]$fit.Percent + '% in GPU memory, the rest runs on the CPU (slower). Lower ContextLength with psai /config.') -ForegroundColor Yellow
        }
    }
}

# Lets the user pick another model and saves it. Returns $true when the model changed.
function Update-PsaiModelChoice {
    param($Config)
    $models = $null
    try {
        $models = Get-PsaiModels -Config $Config
    } catch {
        Write-PsaiError $_.Exception.Message
        return $false
    }
    if ($models.Count -eq 0) {
        Write-PsaiNote 'There are no models on the server.'
        return $false
    }
    $picked = Select-PsaiModel -Config $Config -Models $models
    if ($picked -and -not (Test-PsaiSameModel $picked $Config['Model'])) {
        $Config['Model'] = $picked
        Save-PsaiConfig $Config
        Write-Host ('  Now using ' + $picked) -ForegroundColor Green
        return $true
    }
    return $false
}

function Open-PsaiConfigFile {
    $path = Get-PsaiConfigPath
    if (-not [System.IO.File]::Exists($path)) {
        Write-PsaiNote 'There are no settings yet. Run: psai /setup'
        return
    }
    $editor = $null
    if ($env:TERM_PROGRAM -eq 'vscode') { $editor = Find-PsaiEditorCommand 'code' }
    if ($editor) {
        & $editor --reuse-window $path 2>&1 | Out-Null
    } elseif ($env:OS -eq 'Windows_NT') {
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $path + '"')
    }
    Write-PsaiNote ('Settings file: ' + $path)
    Write-PsaiNote 'Changes apply the next time you start psai. See the README for what each setting does.'
}
