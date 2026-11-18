# Talking to the local AI server.
# psai uses HttpWebRequest instead of Invoke-RestMethod so it can show replies while they
# stream in, let you stop them with Esc, and decode UTF-8 correctly on Windows PowerShell 5.1.

$script:PsaiKeyCaptureDepth = 0
$script:PsaiOldTreatCtrlC = $false

# ---------------------------------------------------------------- keyboard (Esc / Ctrl+C) --

# While psai waits for the model, Ctrl+C is read as a key so it can stop the reply
# instead of closing psai.
function Enter-PsaiKeyCapture {
    $script:PsaiKeyCaptureDepth = $script:PsaiKeyCaptureDepth + 1
    if ($script:PsaiKeyCaptureDepth -gt 1 -or -not $script:PsaiCanReadKeys) { return }
    try {
        $script:PsaiOldTreatCtrlC = [Console]::TreatControlCAsInput
        [Console]::TreatControlCAsInput = $true
    } catch { }
}

function Exit-PsaiKeyCapture {
    if ($script:PsaiKeyCaptureDepth -gt 0) { $script:PsaiKeyCaptureDepth = $script:PsaiKeyCaptureDepth - 1 }
    if ($script:PsaiKeyCaptureDepth -gt 0 -or -not $script:PsaiCanReadKeys) { return }
    try { [Console]::TreatControlCAsInput = $script:PsaiOldTreatCtrlC } catch { }
}

# Returns $true when the user pressed Esc or Ctrl+C.
function Test-PsaiCancelKey {
    if (-not $script:PsaiCanReadKeys) { return $false }
    try {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Escape) { return $true }
            if ($key.Key -eq [ConsoleKey]::C -and (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) { return $true }
        }
    } catch {
        $script:PsaiCanReadKeys = $false
    }
    return $false
}

# --------------------------------------------------------------------------- spinner --

function New-PsaiSpinner {
    param([string]$Text)
    return @{
        Text       = $Text
        Frame      = 0
        Active     = $true
        Shown      = $false
        LastLength = 0
        LastDraw   = -1000
        Clock      = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function Update-PsaiSpinner {
    param($Spinner)
    if ($null -eq $Spinner -or -not $Spinner.Active) { return }
    $ms = $Spinner.Clock.ElapsedMilliseconds
    if (($ms - $Spinner.LastDraw) -lt 90) { return }
    $Spinner.LastDraw = $ms
    $frames = '|/-\'
    $frame = $frames[$Spinner.Frame % 4]
    $Spinner.Frame = $Spinner.Frame + 1
    $seconds = [int][Math]::Floor($ms / 1000)
    $hint = ''
    if ($script:PsaiCanReadKeys) { $hint = ', Esc to stop' }
    $line = '  ' + $frame + ' ' + $Spinner.Text + ' (' + $seconds + 's' + $hint + ')'
    $pad = ''
    if ($Spinner.LastLength -gt $line.Length) { $pad = ' ' * ($Spinner.LastLength - $line.Length) }
    Write-Host -NoNewline ("`r" + $line + $pad) -ForegroundColor DarkGray
    $Spinner.LastLength = $line.Length
    $Spinner.Shown = $true
}

function Stop-PsaiSpinner {
    param($Spinner)
    if ($null -eq $Spinner -or -not $Spinner.Active) { return }
    $Spinner.Active = $false
    if ($Spinner.Shown) {
        Write-Host -NoNewline ("`r" + (' ' * $Spinner.LastLength) + "`r")
    }
}

# --------------------------------------------------------------------------- requests --

function New-PsaiWebRequest {
    param([string]$Method, [string]$Url, [string]$Body, [string]$ApiKey, [int]$TimeoutSec = 15)

    if ($Url.StartsWith('https:', [StringComparison]::OrdinalIgnoreCase)) {
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        } catch { }
    }
    if ($TimeoutSec -le 0) { $TimeoutSec = 300 }
    $request = $null
    try {
        $request = [System.Net.HttpWebRequest]([System.Net.WebRequest]::Create($Url))
    } catch {
        throw ('This is not a valid server address: ' + $Url)
    }
    $request.Method = $Method
    $request.Proxy = $null
    $request.KeepAlive = $false
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000
    $request.Accept = 'application/json, application/x-ndjson, text/event-stream'
    try { $request.ServicePoint.Expect100Continue = $false } catch { }
    if ($ApiKey) { $request.Headers['Authorization'] = 'Bearer ' + $ApiKey }
    if ($Body) {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Body)
        $request.ContentType = 'application/json; charset=utf-8'
        $request.ContentLength = $bytes.Length
        $stream = $null
        try {
            $stream = $request.GetRequestStream()
        } catch {
            throw (Get-PsaiNetworkErrorText -Exception $_.Exception -Url $Url)
        }
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Close() }
    }
    return $request
}

# Starts waiting for the server's answer without blocking the console.
function Start-PsaiResponse {
    param($Request, [string]$Url)
    try {
        return $Request.GetResponseAsync()
    } catch {
        throw (Get-PsaiNetworkErrorText -Exception $_.Exception -Url $Url)
    }
}

# Waits for a .NET task while keeping the spinner moving.
# Returns 'done', 'cancelled' (Esc / Ctrl+C) or 'timeout'.
function Wait-PsaiTask {
    param($Task, [int]$TimeoutSec, $Spinner)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $finished = $false
        try { $finished = $Task.Wait(100) } catch { $finished = $true }
        if ($finished) { return 'done' }
        Update-PsaiSpinner $Spinner
        if (Test-PsaiCancelKey) { return 'cancelled' }
        if ($TimeoutSec -gt 0 -and $clock.Elapsed.TotalSeconds -ge $TimeoutSec) { return 'timeout' }
    }
}

# Returns the task's result, or throws a readable error if the task failed.
function Get-PsaiTaskResult {
    param($Task, [string]$Url)
    if ($Task.IsFaulted -or $Task.IsCanceled) {
        $inner = $null
        if ($Task.Exception) { $inner = $Task.Exception.InnerException }
        throw (Get-PsaiNetworkErrorText -Exception $inner -Url $Url)
    }
    return $Task.Result
}

function Get-PsaiNetworkErrorText {
    param($Exception, [string]$Url)
    $web = $Exception
    while ($null -ne $web -and -not ($web -is [System.Net.WebException])) { $web = $web.InnerException }
    if ($null -ne $web) {
        if ($null -ne $web.Response) {
            $code = 0
            try { $code = [int]$web.Response.StatusCode } catch { }
            $body = ''
            try {
                $reader = New-Object System.IO.StreamReader($web.Response.GetResponseStream(), (New-Object System.Text.UTF8Encoding($false)))
                $body = $reader.ReadToEnd()
                $reader.Dispose()
            } catch { }
            $detail = Get-PsaiErrorFromBody $body
            if ($detail) { return ('The server answered with error ' + $code + ': ' + $detail) }
            return ('The server answered with error ' + $code + '.')
        }
        $status = [string]$web.Status
        if ($status -eq 'ConnectFailure' -or $status -eq 'NameResolutionFailure') {
            return ("Can't connect to " + $Url + '. Is the server running?')
        }
        if ($status -eq 'RequestCanceled') { return 'The request was stopped.' }
        return ("Can't reach " + $Url + ' (' + $web.Message + ')')
    }
    if ($null -ne $Exception) { return $Exception.Message }
    return ('Unknown network error while talking to ' + $Url + '.')
}

function Get-PsaiErrorFromBody {
    param([string]$Body)
    if (-not $Body) { return '' }
    $parsed = ConvertFrom-PsaiJsonSafe $Body
    if ($null -ne $parsed -and $null -ne $parsed.error) {
        return (Get-PsaiErrorText $parsed.error)
    }
    $text = $Body.Trim()
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
    return $text
}

function Get-PsaiErrorText {
    param($ErrorValue)
    if ($ErrorValue -is [string]) { return $ErrorValue }
    if ($null -ne $ErrorValue.message) { return [string]$ErrorValue.message }
    return (ConvertTo-PsaiJson $ErrorValue)
}

# A simple (non-streaming) request. Returns the response text.
# Throws OperationCanceledException when the user presses Esc.
function Invoke-PsaiHttp {
    param(
        [string]$Method = 'GET',
        [string]$Url,
        [string]$Body,
        [string]$ApiKey,
        [int]$TimeoutSec = 15,
        [string]$SpinnerText
    )
    $request = New-PsaiWebRequest -Method $Method -Url $Url -Body $Body -ApiKey $ApiKey -TimeoutSec $TimeoutSec
    $task = Start-PsaiResponse -Request $request -Url $Url
    $spinner = $null
    if ($SpinnerText) { $spinner = New-PsaiSpinner $SpinnerText }
    Enter-PsaiKeyCapture
    try {
        $state = Wait-PsaiTask -Task $task -TimeoutSec $TimeoutSec -Spinner $spinner
    } finally {
        Exit-PsaiKeyCapture
        Stop-PsaiSpinner $spinner
    }
    if ($state -ne 'done') {
        try { $request.Abort() } catch { }
        if ($state -eq 'timeout') { throw ('No answer from ' + $Url + ' after ' + $TimeoutSec + ' seconds.') }
        throw (New-Object System.OperationCanceledException 'Stopped.')
    }
    $response = Get-PsaiTaskResult -Task $task -Url $Url
    try {
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), (New-Object System.Text.UTF8Encoding($false)))
        return $reader.ReadToEnd()
    } finally {
        $response.Close()
    }
}
