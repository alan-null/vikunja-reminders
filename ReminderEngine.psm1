#
# ReminderEngine.psm1
# Pure logic module for Vikunja Reminder Agent.
# Imported by main.ps1 (runtime) and ReminderEngine.Tests.ps1 (tests).
#

Set-StrictMode -Version Latest

# ── Plugin registry ────────────────────────────────────────────────────────────

# Case-sensitive so ContainsKey("Discord") != ContainsKey("discord") — keys are always stored lowercase
$script:_Plugins = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)

function Register-Plugin {
    <#
    .SYNOPSIS
        Registers a notification plugin by name.
    .PARAMETER Name
        Lowercase plugin name. Must match the "plugin" field in rules.json providers.
    .PARAMETER ScriptBlock
        param([hashtable]$Payload, [hashtable]$Options) → $true | $false
    #>
    param(
        [Parameter(Mandatory)][string]      $Name,
        [Parameter(Mandatory)][scriptblock] $ScriptBlock
    )
    $script:_Plugins[$Name.ToLower()] = $ScriptBlock
    Write-Host "  [plugin] Registered: $Name"
}

function Clear-PluginRegistry {
    <#
    .SYNOPSIS
        Clears all registered plugins. Intended for use in tests only.
    #>
    # Case-sensitive so ContainsKey("Discord") != ContainsKey("discord") — keys are always stored lowercase
$script:_Plugins = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
}

function Get-RegisteredPlugins {
    # Returns a shallow copy so callers cannot mutate the registry directly.
    return $script:_Plugins.Clone()
}

# ── Rules engine ───────────────────────────────────────────────────────────────

function Import-RulesConfig {
    <#
    .SYNOPSIS
        Loads and parses rules.json from the given path.
    .PARAMETER Path
        Full path to the rules.json file.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Rules config not found at '$Path'."
    }

    $config = Get-Content $Path -Raw | ConvertFrom-Json

    if ($null -eq $config.providers) { throw "'providers' key missing from config." }
    if ($null -eq $config.rules)     { throw "'rules' key missing from config." }

    return $config
}

function Test-Condition {
    <#
    .SYNOPSIS
        Evaluates a single condition object against a Payload hashtable.
    .OUTPUTS
        [bool]
    #>
    param(
        [Parameter(Mandatory)][hashtable]      $Payload,
        [Parameter(Mandatory)][PSCustomObject] $Condition
    )

    $field = $Condition.field
    $op    = $Condition.op
    $want  = $Condition.value

    $got = switch ($field) {
        "project_id"      { $Payload.ProjectId }
        "priority"        { $Payload.Priority }
        "percent_done"    { $Payload.PercentDone }
        "is_favorite"     { $Payload.IsFavorite }
        "has_attachments" { $Payload.HasAttachments }
        "done"            { $Payload.Done }
        "title"           { $Payload.TaskTitle }
        "description"     { $Payload.Description }
        "labels"          { $Payload.Labels.title }
        "assignees"       { $Payload.AssigneeCount }
        default {
            Write-Warning "  [rules] Unknown condition field '$field' — treating as no-match."
            return $false
        }
    }

    switch ($op) {
        "="           { return $got -eq $want }
        "!="          { return $got -ne $want }
        ">"           { return $got -gt $want }
        ">="          { return $got -ge $want }
        "<"           { return $got -lt $want }
        "<="          { return $got -le $want }
        "contains"    { return ("$got" -like "*$want*") }
        "not_contains"{ return ("$got" -notlike "*$want*") }
        "in"          {
            if ($got -is [System.Array]) {
                $wantArr = @($want)
                $matches = @(@($got) | Where-Object { $wantArr -contains $_ })
                return ($matches.Count -gt 0)
            }
            else {
                return (@($want) -contains $got)
            }
        }
        "not_in"      {
            if ($got -is [System.Array]) {
                $wantArr = @($want)
                $matches = @(@($got) | Where-Object { $wantArr -contains $_ })
                return ($matches.Count -eq 0)
            }
            else {
                return (@($want) -notcontains $got)
            }
        }
        default {
            Write-Warning "  [rules] Unknown operator '$op' — treating as no-match."
            return $false
        }
    }
}

function Resolve-MatchingProviders {
    <#
    .SYNOPSIS
        Evaluates all rules against a Payload and returns the list of provider
        instances to invoke, in order, without duplicates.
    .OUTPUTS
        [System.Collections.Generic.List[hashtable]]
        Each entry: @{ InstanceName; PluginName; Options }
    #>
    param(
        [Parameter(Mandatory)][hashtable]      $Payload,
        [Parameter(Mandatory)][PSCustomObject] $Config
    )

    $providerDefs = @{}
    foreach ($prop in $Config.providers.PSObject.Properties) {
        $providerDefs[$prop.Name] = $prop.Value
    }

    $dispatched = [System.Collections.Generic.HashSet[string]]::new()
    $result     = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($rule in $Config.rules) {
        $conditions = @($rule.conditions)

        $matched = if ($conditions.Count -eq 0) {
            $true   # empty conditions = catch-all
        }
        elseif ($rule.match -eq "any") {
            (@($conditions | Where-Object { Test-Condition -Payload $Payload -Condition $_ })).Count -gt 0
        }
        else {
            # Default: "all" (AND)
            (@($conditions | Where-Object { -not (Test-Condition -Payload $Payload -Condition $_) })).Count -eq 0
        }

        if (-not $matched) { continue }

        Write-Host "  [rules] Matched rule: '$($rule.name)'"

        foreach ($instanceName in $rule.providers) {
            if ($dispatched.Contains($instanceName)) { continue }

            if (-not $providerDefs.ContainsKey($instanceName)) {
                Write-Warning "  [rules] Unknown provider '$instanceName' referenced in rule '$($rule.name)' — skipping."
                continue
            }

            $def = $providerDefs[$instanceName]
            # validate required fields
            $hasPlugin = $def.PSObject.Properties.Name.Contains('plugin')
            if (-not $hasPlugin) {
                Write-Warning "  [rules] Provider '$instanceName' is missing required 'plugin' field — skipping."
                continue
            }

            $options = @{}
            $hasOptions = $def.PSObject.Properties.Name.Contains('options')
            if (-not $hasOptions) {
                Write-Host "  [rules] Provider '$instanceName' is missing 'options' field — treating as empty."

            }else {
                if ($def.options) {
                    foreach ($p in $def.options.PSObject.Properties) { $options[$p.Name] = $p.Value }
                }
            }


            $result.Add(@{
                InstanceName = $instanceName
                PluginName   = $def.plugin.ToLower()
                Options      = $options
            })
            $dispatched.Add($instanceName) | Out-Null
        }

        if ($rule.stop_on_match -eq $true) { break }
    }

    Write-Output $result -NoEnumerate
}

function Invoke-Providers {
    <#
    .SYNOPSIS
        Dispatches a Payload to every provider in the list.
    .OUTPUTS
        [int] Number of providers that returned $true.
    #>
    param(
        [Parameter(Mandatory)][hashtable] $Payload,
        [Parameter(Mandatory)]            $ProviderList   # List[hashtable] or array -- no type constraint to avoid unwrap coercion
    )

    $ok = 0
    foreach ($provider in $ProviderList) {
        $pluginName = $provider.PluginName

        if (-not $script:_Plugins.ContainsKey($pluginName)) {
            Write-Warning "  [$($provider.InstanceName)] No plugin registered for '$pluginName' — skipping."
            continue
        }

        try {
            $result = & $script:_Plugins[$pluginName] $Payload $provider.Options
            if ($result -eq $true) { $ok++ }
            else { Write-Warning "  [$($provider.InstanceName)] returned false." }
        }
        catch {
            Write-Warning "  [$($provider.InstanceName)] threw: $_"
        }
    }
    return $ok
}

# ── Payload builder ────────────────────────────────────────────────────────────

function Build-Payload {
    <#
    .SYNOPSIS
        Builds the normalised Payload hashtable passed to every plugin.
    .PARAMETER Task
        Raw task object from the Vikunja API.
    .PARAMETER ReminderUtc
        The specific reminder datetime (UTC) that triggered this notification.
    .PARAMETER Tz
        User's configured TimeZoneInfo (from Vikunja user settings).
    .PARAMETER PublicBaseUrl
        Base URL used to construct the task link, e.g. http://localhost:3456
    #>
    param(
        [Parameter(Mandatory)][object]              $Task,
        [Parameter(Mandatory)][datetime]            $ReminderUtc,
        [Parameter(Mandatory)][System.TimeZoneInfo] $Tz,
        [Parameter(Mandatory)][string]              $PublicBaseUrl
    )

    $localTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($ReminderUtc, $Tz)
    $offset    = $Tz.GetUtcOffset($ReminderUtc)
    $sign      = if ($offset.TotalSeconds -ge 0) { '+' } else { '-' }
    $offsetStr = "UTC{0}{1:hh\:mm}" -f $sign, $offset

    return @{
        TaskId         = [int]   $Task.id
        TaskTitle      = [string]$Task.title
        TaskUrl        = "$($PublicBaseUrl.TrimEnd('/'))/tasks/$($Task.id)"
        Description    = [string]$Task.description
        ProjectId      = [int]   $Task.project_id
        Done           = [bool]  $Task.done
        Priority       = [int]   $Task.priority
        PercentDone    = [int]   $Task.percent_done
        IsFavorite     = [bool]  $Task.is_favorite
        HasAttachments = ($null -ne $Task.attachments -and @($Task.attachments).Count -gt 0)
        LabelCount     = if ($null -eq $Task.labels)    { 0 } else { @($Task.labels).Count }
        Labels         = if ($null -eq $Task.labels)    { @() } else { $Task.labels }
        AssigneeCount  = if ($null -eq $Task.assignees) { 0 } else { @($Task.assignees).Count }
        ReminderUtc    = $ReminderUtc
        ReminderLocal  = $localTime
        ReminderStr    = "$($localTime.ToString('yyyy-MM-dd HH:mm'))  ($offsetStr)"
        Timezone       = $Tz
    }
}

# ── State helpers ──────────────────────────────────────────────────────────────

function Get-FiredReminders {
    param([Parameter(Mandatory)][string]$Path)

    $set = [System.Collections.Generic.HashSet[string]]::new()
    if (Test-Path $Path) {
        try {
            $raw = Get-Content $Path -Raw | ConvertFrom-Json
            foreach ($k in $raw) { $set.Add($k) | Out-Null }
        }
        catch { Write-Warning "Could not read state file '$Path', starting fresh. Error: $_" }
    }
    Write-Output $set -NoEnumerate
}

function Save-FiredReminders {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$Set,
        [Parameter(Mandatory)][string]$Path
    )
    $entries = @($Set)
    if ($entries.Count -gt 2000) { $entries = $entries | Select-Object -Last 2000 }
    $entries | ConvertTo-Json | Set-Content $Path
}

# ── Exports ────────────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Register-Plugin'
    'Clear-PluginRegistry'
    'Get-RegisteredPlugins'
    'Import-RulesConfig'
    'Test-Condition'
    'Resolve-MatchingProviders'
    'Invoke-Providers'
    'Build-Payload'
    'Get-FiredReminders'
    'Save-FiredReminders'
)
