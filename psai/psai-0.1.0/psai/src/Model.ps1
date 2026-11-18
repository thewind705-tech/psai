# Sending a conversation to the model and reading the streamed reply.
# Ollama:    POST /api/chat             (one JSON object per line)
# LM Studio: POST /v1/chat/completions  (OpenAI-style "data: {...}" lines)
#
# Messages are kept in one neutral format inside psai:
#   @{ role = 'system' | 'user' | 'assistant' | 'tool'; content = '...' }
#   assistant messages may have tool_calls = @( @{ id; name; arguments = <hashtable> } )
#   tool messages have tool_call_id and name

function New-PsaiCallId {
    return ('call_' + [guid]::NewGuid().ToString('N').Substring(0, 12))
}

# Tool arguments arrive either as an object (Ollama) or as a JSON string (LM Studio).
# Returns a hashtable, or $null when the arguments can't be read.
function ConvertTo-PsaiArguments {
    param($Value)
    if ($null -eq $Value) { return (New-PsaiMap) }
    if ($Value -is [string]) {
        if ($Value.Trim() -eq '') { return (New-PsaiMap) }
        $parsed = ConvertFrom-PsaiJsonSafe $Value
        if ($null -eq $parsed) { return $null }
        $Value = $parsed
    }
    $map = ConvertTo-PsaiMap $Value
    if ($map -is [hashtable]) { return $map }
    return $null
}

function ConvertTo-PsaiWireMessages {
    param($Config, $Messages)
    $isOllama = ($Config['Provider'] -eq 'ollama')
    $wire = New-Object System.Collections.Generic.List[object]
    foreach ($m in $Messages) {
        $out = [ordered]@{ role = [string]$m.role; content = [string]$m.content }
        if ($m.role -eq 'assistant' -and $m.tool_calls -and @($m.tool_calls).Count -gt 0) {
            $calls = New-Object System.Collections.Generic.List[object]
            foreach ($tc in $m.tool_calls) {
                $callArgs = $tc.arguments
                if ($null -eq $callArgs) { $callArgs = New-PsaiMap }
                if ($isOllama) {
                    $calls.Add([ordered]@{ 'function' = [ordered]@{ name = [string]$tc.name; arguments = $callArgs } })
                } else {
                    $calls.Add([ordered]@{
                            id         = [string]$tc.id
                            type       = 'function'
                            'function' = [ordered]@{ name = [string]$tc.name; arguments = (ConvertTo-PsaiJson $callArgs) }
                        })
                }
            }
            $out['tool_calls'] = $calls.ToArray()
        }
        if ($m.role -eq 'tool') {
            if ($isOllama) {
                $out['tool_name'] = [string]$m.name
            } else {
                $out['tool_call_id'] = [string]$m.tool_call_id
            }
        }
        $wire.Add($out)
    }
    return , $wire.ToArray()
}

function New-PsaiChatBody {
    param($Config, $Messages, $Tools, [bool]$IncludeThink)
    $body = [ordered]@{
        model    = [string]$Config['Model']
        messages = (ConvertTo-PsaiWireMessages -Config $Config -Messages $Messages)
        stream   = $true
    }
    if ($Tools) { $body['tools'] = $Tools }
    if ($Config['Provider'] -eq 'ollama') {
        $options = [ordered]@{}
        if ([int]$Config['ContextLength'] -gt 0) { $options['num_ctx'] = [int]$Config['ContextLength'] }
        if ($null -ne $Config['Temperature']) { $options['temperature'] = [double]$Config['Temperature'] }
        $body['options'] = $options
        if ($IncludeThink -and $null -ne $Config['Think']) { $body['think'] = [bool]$Config['Think'] }
    } else {
        if ($null -ne $Config['Temperature']) { $body['temperature'] = [double]$Config['Temperature'] }
    }
    return (ConvertTo-PsaiJson $body)
}

# Sends the conversation and streams the reply to the screen.
# Returns @{ content; thinking; tool_calls (List); cancelled }.
function Invoke-PsaiModel {
    param($Config, $Messages, $Tools = $null, [switch]$Silent)
    $base = ([string]$Config['Url']).TrimEnd('/')
    if ($Config['Provider'] -eq 'ollama') { $url = $base + '/api/chat' } else { $url = $base + '/v1/chat/completions' }

    $includeThink = $true
    while ($true) {
        $body = New-PsaiChatBody -Config $Config -Messages $Messages -Tools $Tools -IncludeThink $includeThink
        try {
            return (Invoke-PsaiModelOnce -Config $Config -Url $url -Body $body -Silent ([bool]$Silent))
        } catch {
            # Some models reject the "think" setting; try once more without it.
            if ($includeThink -and $null -ne $Config['Think'] -and (Test-PsaiText $_.Exception.Message 'think')) {
                $includeThink = $false
                continue
            }
            throw
        }
    }
}

function Invoke-PsaiModelOnce {
    param($Config, [string]$Url, [string]$Body, [bool]$Silent)

    $isOllama = ($Config['Provider'] -eq 'ollama')
    $result = @{
        content    = ''
        thinking   = ''
        tool_calls = (New-Object System.Collections.Generic.List[object])
        cancelled  = $false
    }
    $timeout = [int]$Config['RequestTimeoutSec']
    if ($timeout -le 0) { $timeout = 300 }
    $view = New-PsaiView -Config $Config -Silent $Silent
    $partialCalls = @{}   # LM Studio sends tool calls in pieces, keyed by index

    $request = $null
    $response = $null
    $reader = $null
    $finished = $false
    Enter-PsaiKeyCapture
    try {
        $request = New-PsaiWebRequest -Method 'POST' -Url $Url -Body $Body -ApiKey $Config['ApiKey'] -TimeoutSec $timeout
        $responseTask = Start-PsaiResponse -Request $request -Url $Url
        $state = Wait-PsaiTask -Task $responseTask -TimeoutSec $timeout -Spinner $view.Spinner
        if ($state -eq 'cancelled') {
            $result.cancelled = $true
            return $result
        }
        if ($state -eq 'timeout') { throw ('The model did not answer within ' + $timeout + ' seconds.') }
        $response = Get-PsaiTaskResult -Task $responseTask -Url $Url
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), (New-Object System.Text.UTF8Encoding($false)))

        while ($true) {
            $lineTask = $reader.ReadLineAsync()
            $state = Wait-PsaiTask -Task $lineTask -TimeoutSec $timeout -Spinner $view.Spinner
            if ($state -eq 'cancelled') {
                $result.cancelled = $true
                break
            }
            if ($state -eq 'timeout') { throw ('The model stopped sending text (nothing for ' + $timeout + ' seconds).') }
            $line = Get-PsaiTaskResult -Task $lineTask -Url $Url
            if ($null -eq $line) { break }
            $line = $line.Trim()
            if ($line.Length -eq 0) { continue }

            if ($isOllama) {
                $chunk = ConvertFrom-PsaiJsonSafe $line
                if ($null -eq $chunk) { continue }
                if ($chunk.error) { throw (Get-PsaiErrorText $chunk.error) }
                $message = $chunk.message
                if ($message) {
                    if ($message.thinking) { Add-PsaiViewThinking $view ([string]$message.thinking) }
                    if ($message.content) { Add-PsaiViewContent $view ([string]$message.content) }
                    if ($message.tool_calls) {
                        foreach ($tc in @($message.tool_calls)) {
                            $fn = $tc.'function'
                            if ($null -eq $fn) { continue }
                            $id = [string]$tc.id
                            if (-not $id) { $id = New-PsaiCallId }
                            $callArgs = ConvertTo-PsaiArguments $fn.arguments
                            $call = @{ id = $id; name = [string]$fn.name; arguments = $callArgs; error = $null }
                            if ($null -eq $callArgs) { $call.error = 'The tool arguments were not valid JSON.' }
                            $result.tool_calls.Add($call)
                        }
                    }
                }
                if ($chunk.done -eq $true) { break }
            } else {
                if (-not $line.StartsWith('data:', [StringComparison]::Ordinal)) {
                    if ($line.StartsWith('{', [StringComparison]::Ordinal)) {
                        $chunk = ConvertFrom-PsaiJsonSafe $line
                        if ($null -ne $chunk -and $chunk.error) { throw (Get-PsaiErrorText $chunk.error) }
                    }
                    continue
                }
                $data = $line.Substring(5).Trim()
                if ($data -eq '[DONE]') { break }
                $chunk = ConvertFrom-PsaiJsonSafe $data
                if ($null -eq $chunk) { continue }
                if ($chunk.error) { throw (Get-PsaiErrorText $chunk.error) }
                $choices = @($chunk.choices)
                if ($choices.Count -eq 0 -or $null -eq $choices[0]) { continue }
                $delta = $choices[0].delta
                if ($null -eq $delta) { continue }
                if ($delta.reasoning_content) {
                    Add-PsaiViewThinking $view ([string]$delta.reasoning_content)
                } elseif ($delta.reasoning) {
                    Add-PsaiViewThinking $view ([string]$delta.reasoning)
                }
                if ($delta.content) { Add-PsaiViewContent $view ([string]$delta.content) }
                if ($delta.tool_calls) {
                    foreach ($tc in @($delta.tool_calls)) {
                        $index = 0
                        if ($null -ne $tc.index) { $index = [int]$tc.index }
                        $partial = $partialCalls[$index]
                        if ($null -eq $partial) {
                            $partial = @{ id = ''; name = ''; args = (New-Object System.Text.StringBuilder) }
                            $partialCalls[$index] = $partial
                        }
                        if ($tc.id) { $partial.id = [string]$tc.id }
                        $fn = $tc.'function'
                        if ($null -ne $fn) {
                            if ($fn.name) { $partial.name = [string]$fn.name }
                            if ($null -ne $fn.arguments) {
                                if ($fn.arguments -is [string]) {
                                    [void]$partial.args.Append($fn.arguments)
                                } else {
                                    [void]$partial.args.Append((ConvertTo-PsaiJson $fn.arguments))
                                }
                            }
                        }
                    }
                }
            }
        }
        $finished = -not $result.cancelled
    } finally {
        Exit-PsaiKeyCapture
        # Stop the download when the reply was cancelled or something went wrong.
        if (-not $finished -and $null -ne $request) { try { $request.Abort() } catch { } }
        if ($null -ne $reader) { try { $reader.Dispose() } catch { } }
        if ($null -ne $response) { try { $response.Close() } catch { } }
        Complete-PsaiView $view
    }

    foreach ($index in @($partialCalls.Keys | Sort-Object)) {
        $partial = $partialCalls[$index]
        $callArgs = ConvertTo-PsaiArguments $partial.args.ToString()
        $id = $partial.id
        if (-not $id) { $id = New-PsaiCallId }
        $call = @{ id = $id; name = $partial.name; arguments = $callArgs; error = $null }
        if ($null -eq $callArgs) { $call.error = 'The tool arguments were not valid JSON: ' + $partial.args.ToString() }
        $result.tool_calls.Add($call)
    }

    $result.content = Get-PsaiViewAnswer $view
    $result.thinking = $view.Thinking.ToString()
    return $result
}

# ------------------------------------------------------------------------ reply view --
# Splits the streamed text into "thinking" and the answer, shows a spinner while the
# model thinks (or the thinking itself in gray when ShowThinking is on) and renders the answer.

function New-PsaiView {
    param($Config, [bool]$Silent)
    $spinner = $null
    if (-not $Silent) { $spinner = New-PsaiSpinner 'waiting for the model' }
    return @{
        Raw           = (New-Object System.Text.StringBuilder)
        Thinking      = (New-Object System.Text.StringBuilder)
        ThinkPrinted  = 0
        AnswerPrinted = 0
        ShowThinking  = [bool]$Config['ShowThinking']
        ThinkShown    = $false
        AnswerStarted = $false
        Spinner       = $spinner
        Renderer      = (New-PsaiRenderer)
        Silent        = $Silent
    }
}

function Write-PsaiThinkingText {
    param($View, [string]$Text)
    if ($View.Silent -or $Text.Length -eq 0) { return }
    if ($View.ShowThinking) {
        Stop-PsaiSpinner $View.Spinner
        if (-not $View.ThinkShown) {
            $View.ThinkShown = $true
            $Text = $Text.TrimStart()
        }
        Write-Host -NoNewline $Text -ForegroundColor DarkGray
    } elseif ($null -ne $View.Spinner) {
        $View.Spinner.Text = 'thinking'
        Update-PsaiSpinner $View.Spinner
    }
}

function Write-PsaiAnswerText {
    param($View, [string]$Text)
    if ($View.Silent -or $Text.Length -eq 0) { return }
    Stop-PsaiSpinner $View.Spinner
    if (-not $View.AnswerStarted) {
        $View.AnswerStarted = $true
        if ($View.ThinkShown) {
            Write-Host ''
            Write-Host ''
        }
    }
    Add-PsaiRenderText $View.Renderer $Text
}

function Add-PsaiViewThinking {
    param($View, [string]$Text)
    [void]$View.Thinking.Append($Text)
    Write-PsaiThinkingText $View $Text
}

# Some models put their thinking inside the answer as <think> ... </think>.
function Add-PsaiViewContent {
    param($View, [string]$Text)
    [void]$View.Raw.Append($Text)
    $raw = $View.Raw.ToString()
    $trimmed = $raw.TrimStart()
    $think = ''
    $answer = ''
    if ($trimmed.StartsWith('<think>', [StringComparison]::Ordinal)) {
        $rest = $trimmed.Substring(7)
        $end = $rest.IndexOf('</think>', [StringComparison]::Ordinal)
        if ($end -ge 0) {
            $think = $rest.Substring(0, $end)
            $answer = $rest.Substring($end + 8).TrimStart()
        } else {
            # Hold back a half-arrived "</think>" at the end.
            $think = $rest
            for ($k = [Math]::Min(7, $rest.Length); $k -ge 1; $k--) {
                if ($rest.EndsWith('</think>'.Substring(0, $k), [StringComparison]::Ordinal)) {
                    $think = $rest.Substring(0, $rest.Length - $k)
                    break
                }
            }
        }
    } elseif ($trimmed.Length -lt 7 -and '<think>'.StartsWith($trimmed, [StringComparison]::Ordinal)) {
        return   # might still become "<think>", wait for more text
    } else {
        $answer = $trimmed
    }
    if ($think.Length -gt $View.ThinkPrinted) {
        Write-PsaiThinkingText $View $think.Substring($View.ThinkPrinted)
        $View.ThinkPrinted = $think.Length
    }
    if ($answer.Length -gt $View.AnswerPrinted) {
        $delta = $answer.Substring($View.AnswerPrinted)
        $View.AnswerPrinted = $answer.Length
        Write-PsaiAnswerText $View $delta
    }
}

function Complete-PsaiView {
    param($View)
    if ($View.Silent) { return }
    Stop-PsaiSpinner $View.Spinner
    if ($View.AnswerStarted) {
        Complete-PsaiRender $View.Renderer
    } elseif ($View.ThinkShown) {
        Write-Host ''
    }
}

# The answer without any <think> part, as it is stored in the conversation.
function Get-PsaiViewAnswer {
    param($View)
    $text = $View.Raw.ToString().TrimStart()
    if ($text.StartsWith('<think>', [StringComparison]::Ordinal)) {
        $end = $text.IndexOf('</think>', [StringComparison]::Ordinal)
        if ($end -lt 0) { return '' }
        return $text.Substring($end + 8).Trim()
    }
    $end = $text.LastIndexOf('</think>', [StringComparison]::Ordinal)
    if ($end -ge 0) { return $text.Substring($end + 8).Trim() }
    return $text.Trim()
}

# Keeps the conversation inside the model's context window by leaving out the oldest
# messages. The latest request from the user is always kept.
function Limit-PsaiHistory {
    param($Messages, $Config, [int]$ExtraChars = 0)
    $ctx = [int]$Config['ContextLength']
    if ($ctx -le 0) { $ctx = 8192 }
    $reserve = [Math]::Min(2048, [int][Math]::Floor($ctx / 4))
    $budget = ($ctx - $reserve) * 3 - $ExtraChars   # roughly 3 characters per token
    $dropped = 0
    while ((Measure-PsaiChars $Messages) -gt $budget) {
        $taskIndex = -1
        for ($i = $Messages.Count - 1; $i -ge 1; $i--) {
            if ($Messages[$i]['task']) {
                $taskIndex = $i
                break
            }
        }
        if ($taskIndex -gt 1) {
            $at = 1
        } elseif ($taskIndex -ge 1 -and ($Messages.Count - $taskIndex) -gt 3) {
            $at = $taskIndex + 1
        } elseif ($taskIndex -lt 0 -and $Messages.Count -gt 3) {
            $at = 1
        } else {
            break
        }
        $Messages.RemoveAt($at)
        $dropped++
        while ($at -lt $Messages.Count -and $Messages[$at]['role'] -eq 'tool') {
            $Messages.RemoveAt($at)
            $dropped++
        }
    }
    if ($dropped -gt 0) {
        Write-PsaiNote ('(left out ' + $dropped + ' older messages so the conversation fits in the model''s memory)')
    }
}

# How much tool output (file text, command output) to hand the model at once:
# MaxToolOutputChars, but never more than about a third of the context.
function Get-PsaiToolOutputLimit {
    param($Config)
    $max = [int]$Config['MaxToolOutputChars']
    if ($max -le 0) { $max = 12000 }
    $ctx = [int]$Config['ContextLength']
    if ($ctx -le 0) { $ctx = 8192 }
    $reserve = [Math]::Min(2048, [int][Math]::Floor($ctx / 4))
    $fit = $ctx - $reserve
    if ($fit -lt 2000) { $fit = 2000 }
    return [Math]::Min($max, $fit)
}

function Measure-PsaiChars {
    param($Messages)
    $total = 0
    foreach ($m in $Messages) {
        $total += ([string]$m['content']).Length + 20
        if ($m['tool_calls']) {
            foreach ($tc in $m['tool_calls']) { $total += (ConvertTo-PsaiJson $tc.arguments).Length + 40 }
        }
    }
    return $total
}
