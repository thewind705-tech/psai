# JSON helpers.
# psai writes its own JSON because ConvertTo-Json in Windows PowerShell 5.1 cuts off nested
# data (default depth 2) and sometimes adds extra properties to strings.

$script:PsaiJsonControlChars = [char[]](0..31)

function ConvertTo-PsaiJson {
    param(
        $Value,
        [switch]$Pretty
    )
    $builder = New-Object System.Text.StringBuilder
    Write-PsaiJsonValue -Builder $builder -Value $Value -Pretty ([bool]$Pretty) -Level 0
    return $builder.ToString()
}

function ConvertTo-PsaiJsonString {
    param([string]$Text)
    $s = $Text.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    if ($s.IndexOfAny($script:PsaiJsonControlChars) -ge 0) {
        $s = [regex]::Replace($s, '[\x00-\x1F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
    }
    return '"' + $s + '"'
}

function Write-PsaiJsonValue {
    param($Builder, $Value, [bool]$Pretty, [int]$Level)

    if ($null -eq $Value) {
        [void]$Builder.Append('null')
        return
    }
    if ($Value -is [string] -or $Value -is [char]) {
        [void]$Builder.Append((ConvertTo-PsaiJsonString ([string]$Value)))
        return
    }
    if ($Value -is [bool]) {
        if ($Value) { [void]$Builder.Append('true') } else { [void]$Builder.Append('false') }
        return
    }
    if ($Value -is [System.Management.Automation.SwitchParameter]) {
        if ($Value.IsPresent) { [void]$Builder.Append('true') } else { [void]$Builder.Append('false') }
        return
    }
    if ($Value -is [double] -or $Value -is [single]) {
        $d = [double]$Value
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) {
            [void]$Builder.Append('null')
        } else {
            [void]$Builder.Append($d.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture))
        }
        return
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [int16] -or
        $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64]) {
        [void]$Builder.Append($Value.ToString([System.Globalization.CultureInfo]::InvariantCulture))
        return
    }
    if ($Value -is [datetime]) {
        [void]$Builder.Append((ConvertTo-PsaiJsonString ($Value.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture))))
        return
    }
    if ($Value -is [enum]) {
        [void]$Builder.Append((ConvertTo-PsaiJsonString ($Value.ToString())))
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = New-Object System.Collections.Generic.List[object]
        foreach ($key in @($Value.Keys)) { $pairs.Add(@([string]$key, $Value[$key])) }
        Write-PsaiJsonObject -Builder $Builder -Pairs $pairs -Pretty $Pretty -Level $Level
        return
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $pairs = New-Object System.Collections.Generic.List[object]
        foreach ($prop in $Value.PSObject.Properties) { $pairs.Add(@([string]$prop.Name, $prop.Value)) }
        Write-PsaiJsonObject -Builder $Builder -Pairs $pairs -Pretty $Pretty -Level $Level
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) { $items.Add($item) }
        Write-PsaiJsonArray -Builder $Builder -Items $items -Pretty $Pretty -Level $Level
        return
    }
    [void]$Builder.Append((ConvertTo-PsaiJsonString ([string]$Value)))
}

function Write-PsaiJsonObject {
    param($Builder, $Pairs, [bool]$Pretty, [int]$Level)
    if ($Pairs.Count -eq 0) {
        [void]$Builder.Append('{}')
        return
    }
    [void]$Builder.Append('{')
    $first = $true
    foreach ($pair in $Pairs) {
        if (-not $first) { [void]$Builder.Append(',') }
        $first = $false
        if ($Pretty) { [void]$Builder.Append("`n").Append('  ' * ($Level + 1)) }
        [void]$Builder.Append((ConvertTo-PsaiJsonString $pair[0])).Append(':')
        if ($Pretty) { [void]$Builder.Append(' ') }
        Write-PsaiJsonValue -Builder $Builder -Value $pair[1] -Pretty $Pretty -Level ($Level + 1)
    }
    if ($Pretty) { [void]$Builder.Append("`n").Append('  ' * $Level) }
    [void]$Builder.Append('}')
}

function Write-PsaiJsonArray {
    param($Builder, $Items, [bool]$Pretty, [int]$Level)
    if ($Items.Count -eq 0) {
        [void]$Builder.Append('[]')
        return
    }
    [void]$Builder.Append('[')
    $first = $true
    foreach ($item in $Items) {
        if (-not $first) { [void]$Builder.Append(',') }
        $first = $false
        if ($Pretty) { [void]$Builder.Append("`n").Append('  ' * ($Level + 1)) }
        Write-PsaiJsonValue -Builder $Builder -Value $item -Pretty $Pretty -Level ($Level + 1)
    }
    if ($Pretty) { [void]$Builder.Append("`n").Append('  ' * $Level) }
    [void]$Builder.Append(']')
}

# Parses JSON and returns $null instead of throwing when the text is not valid JSON.
function ConvertFrom-PsaiJsonSafe {
    param([string]$Json)
    if (-not $Json) { return $null }
    try {
        return (ConvertFrom-Json -InputObject $Json)
    } catch {
        return $null
    }
}

# A hashtable whose keys ignore upper/lower case the same way on every system language.
# (Normal PowerShell hashtables follow the system language, which can break keys
# such as "id" vs "ID" on Turkish Windows.)
function New-PsaiMap {
    return (New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase))
}

# Turns parsed JSON (PSCustomObject trees) into hashtables and arrays.
function ConvertTo-PsaiMap {
    param($Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $map = New-PsaiMap
        foreach ($prop in $Object.PSObject.Properties) { $map[$prop.Name] = ConvertTo-PsaiMap $prop.Value }
        return $map
    }
    if ($Object -is [System.Collections.IDictionary]) {
        $map = New-PsaiMap
        foreach ($key in @($Object.Keys)) { $map[[string]$key] = ConvertTo-PsaiMap $Object[$key] }
        return $map
    }
    if ($Object -is [string]) { return $Object }
    if ($Object -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Object) { $list.Add((ConvertTo-PsaiMap $item)) }
        return , $list.ToArray()
    }
    return $Object
}
