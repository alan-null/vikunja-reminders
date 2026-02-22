#Requires -Modules Pester
#
# ReminderEngine.Tests.ps1
# Run with: pwsh -Command "Invoke-Pester -Output Detailed"
#
# Covers:
#   - Test-Condition  (all fields, all operators, edge cases)
#   - Resolve-MatchingProviders  (match modes, stop_on_match, dedup, unknown provider)
#   - Invoke-Providers  (success, failure, exception, unknown plugin)
#   - Build-Payload  (field mapping, timezone, URL construction)
#   - Register-Plugin / Clear-PluginRegistry

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot "ReminderEngine.psm1"
    Import-Module $modulePath -Force

    # ── Helpers ────────────────────────────────────────────────────────────────────
    function New-Condition {
        param([string]$Field, [string]$Op, $Value)
        [PSCustomObject]@{ field = $Field; op = $Op; value = $Value }
    }

    function New-Payload {
        param(
            [int]    $TaskId = 1,
            [string] $TaskTitle = "Test Task",
            [string] $Description = "",
            [int]    $ProjectId = 1,
            [bool]   $Done = $false,
            [int]    $Priority = 0,
            [int]    $PercentDone = 0,
            [bool]   $IsFavorite = $false,
            [bool]   $HasAttachments = $false,
            [int]    $LabelCount = 0,
            [array] $Labels = @(),
            [int]    $AssigneeCount = 0
        )
        if ($PSBoundParameters.ContainsKey('Labels') -and $null -ne $Labels) { $LabelCount = @($Labels).Count }
        @{
            TaskId         = $TaskId
            TaskTitle      = $TaskTitle
            TaskUrl        = "http://localhost:3456/tasks/$TaskId"
            Description    = $Description
            ProjectId      = $ProjectId
            Done           = $Done
            Priority       = $Priority
            PercentDone    = $PercentDone
            IsFavorite     = $IsFavorite
            HasAttachments = $HasAttachments
            LabelCount     = $LabelCount
            Labels         = $Labels
            AssigneeCount  = $AssigneeCount
            ReminderUtc    = [datetime]::UtcNow
            ReminderLocal  = [datetime]::Now
            ReminderStr    = "2026-02-22 22:21  (UTC+01:00)"
            Timezone       = [System.TimeZoneInfo]::Utc
        }
    }

    function New-Config {
        param($Providers, $Rules)

        $providersHt = @{}
        foreach ($p in @($Providers)) {
            $providersHt[$p.name] = @{
                plugin  = $p.plugin
                options = if ($p.options) { $p.options } else { @{} }
            }
        }

        $rulesArr = @(@($Rules) | ForEach-Object {
                [PSCustomObject]@{
                    name          = $_.name
                    match         = if ($_.match) { $_.match } else { 'all' }
                    stop_on_match = if ($_.stop_on_match) { $true } else { $false }
                    providers     = @($_.providers)
                    conditions    = @(
                        if ($_.conditions) {
                            $_.conditions | ForEach-Object {
                                [PSCustomObject]@{ field = $_.field; op = $_.op; value = $_.value }
                            }
                        }
                    )
                }
            })

        [PSCustomObject]@{
            providers = [PSCustomObject]$providersHt
            rules     = $rulesArr
        } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    }

    function New-ProviderList {
        param([string]$InstanceName, [string]$PluginName, [hashtable]$Options = @{})
        $list = [System.Collections.Generic.List[hashtable]]::new()
        $list.Add(@{ InstanceName = $InstanceName; PluginName = $PluginName; Options = $Options })
        return $list
    }
}


# ══════════════════════════════════════════════════════════════════════════════
# Test-Condition
# ══════════════════════════════════════════════════════════════════════════════

Describe "Test-Condition" {

    Context "Field resolution" {
        It "resolves project_id" {
            $p = New-Payload -ProjectId 5
            Test-Condition -Payload $p -Condition (New-Condition "project_id" "=" 5) | Should -BeTrue
        }
        It "resolves priority" {
            $p = New-Payload -Priority 3
            Test-Condition -Payload $p -Condition (New-Condition "priority" "=" 3) | Should -BeTrue
        }
        It "resolves percent_done" {
            $p = New-Payload -PercentDone 75
            Test-Condition -Payload $p -Condition (New-Condition "percent_done" ">=" 50) | Should -BeTrue
        }
        It "resolves is_favorite" {
            $p = New-Payload -IsFavorite $true
            Test-Condition -Payload $p -Condition (New-Condition "is_favorite" "=" $true) | Should -BeTrue
        }
        It "resolves has_attachments" {
            $p = New-Payload -HasAttachments $true
            Test-Condition -Payload $p -Condition (New-Condition "has_attachments" "=" $true) | Should -BeTrue
        }
        It "resolves done" {
            $p = New-Payload -Done $false
            Test-Condition -Payload $p -Condition (New-Condition "done" "=" $false) | Should -BeTrue
        }
        It "resolves title" {
            $p = New-Payload -TaskTitle "Buy milk"
            Test-Condition -Payload $p -Condition (New-Condition "title" "contains" "milk") | Should -BeTrue
        }
        It "resolves description" {
            $p = New-Payload -Description "Do it fast"
            Test-Condition -Payload $p -Condition (New-Condition "description" "contains" "fast") | Should -BeTrue
        }
        It "resolves labels by title" {
            $p = New-Payload -Labels @([PSCustomObject]@{ id = 1; title = "a" }, [PSCustomObject]@{ id = 2; title = "b" })
            Test-Condition -Payload $p -Condition (New-Condition "labels" "in" @("b")) | Should -BeTrue
        }
        It "resolves assignees count" {
            $p = New-Payload -AssigneeCount 2
            Test-Condition -Payload $p -Condition (New-Condition "assignees" ">=" 1) | Should -BeTrue
        }
        It "returns false for unknown field" {
            $p = New-Payload
            Test-Condition -Payload $p -Condition (New-Condition "nonexistent_field" "=" 1) | Should -BeFalse
        }
    }

    Context "Operator '='" {
        It "matches equal int" {
            Test-Condition -Payload (New-Payload -Priority 2) -Condition (New-Condition "priority" "=" 2) | Should -BeTrue
        }
        It "does not match different int" {
            Test-Condition -Payload (New-Payload -Priority 2) -Condition (New-Condition "priority" "=" 3) | Should -BeFalse
        }
        It "matches equal bool true" {
            Test-Condition -Payload (New-Payload -IsFavorite $true) -Condition (New-Condition "is_favorite" "=" $true) | Should -BeTrue
        }
        It "does not match mismatched bool" {
            Test-Condition -Payload (New-Payload -IsFavorite $false) -Condition (New-Condition "is_favorite" "=" $true) | Should -BeFalse
        }
    }

    Context "Operator '!='" {
        It "matches when values differ" {
            Test-Condition -Payload (New-Payload -Priority 1) -Condition (New-Condition "priority" "!=" 3) | Should -BeTrue
        }
        It "does not match when values are equal" {
            Test-Condition -Payload (New-Payload -Priority 3) -Condition (New-Condition "priority" "!=" 3) | Should -BeFalse
        }
    }

    Context "Operators '>' '>=' '<' '<='" {
        It "> passes when greater" {
            Test-Condition -Payload (New-Payload -Priority 4) -Condition (New-Condition "priority" ">" 3) | Should -BeTrue
        }
        It "> fails when equal" {
            Test-Condition -Payload (New-Payload -Priority 3) -Condition (New-Condition "priority" ">" 3) | Should -BeFalse
        }
        It ">= passes when equal" {
            Test-Condition -Payload (New-Payload -Priority 3) -Condition (New-Condition "priority" ">=" 3) | Should -BeTrue
        }
        It "< passes when less" {
            Test-Condition -Payload (New-Payload -PercentDone 20) -Condition (New-Condition "percent_done" "<" 50) | Should -BeTrue
        }
        It "< fails when equal" {
            Test-Condition -Payload (New-Payload -PercentDone 50) -Condition (New-Condition "percent_done" "<" 50) | Should -BeFalse
        }
        It "<= passes when equal" {
            Test-Condition -Payload (New-Payload -PercentDone 50) -Condition (New-Condition "percent_done" "<=" 50) | Should -BeTrue
        }
    }

    Context "Operator 'contains' / 'not_contains'" {
        It "contains matches substring" {
            Test-Condition -Payload (New-Payload -TaskTitle "Buy milk today") -Condition (New-Condition "title" "contains" "milk") | Should -BeTrue
        }
        It "contains is case-insensitive (PowerShell -like)" {
            Test-Condition -Payload (New-Payload -TaskTitle "Buy MILK today") -Condition (New-Condition "title" "contains" "milk") | Should -BeTrue
        }
        It "contains fails when substring absent" {
            Test-Condition -Payload (New-Payload -TaskTitle "Buy bread") -Condition (New-Condition "title" "contains" "milk") | Should -BeFalse
        }
        It "not_contains passes when substring absent" {
            Test-Condition -Payload (New-Payload -TaskTitle "Buy bread") -Condition (New-Condition "title" "not_contains" "milk") | Should -BeTrue
        }
        It "not_contains fails when substring present" {
            Test-Condition -Payload (New-Payload -TaskTitle "Buy milk") -Condition (New-Condition "title" "not_contains" "milk") | Should -BeFalse
        }
        It "contains treats value as a glob - * in value acts as wildcard not a literal character" {
            # The implementation uses -like "*$want*", so * inside want is also a glob wildcard.
            # "m*lk" therefore matches "milk" (any char between m and lk).
            Test-Condition -Payload (New-Payload -TaskTitle "milk") -Condition (New-Condition "title" "contains" "m*lk") | Should -BeTrue
        }
        It "contains empty string value matches any title" {
            # -like "**" is always true; an empty search term is a catch-all.
            Test-Condition -Payload (New-Payload -TaskTitle "Anything at all") -Condition (New-Condition "title" "contains" "") | Should -BeTrue
        }
    }

    Context "Operator 'in' / 'not_in'" {
        It "in matches when value is in list" {
            $c = [PSCustomObject]@{ field = "project_id"; op = "in"; value = @(1, 2, 3) }
            Test-Condition -Payload (New-Payload -ProjectId 2) -Condition $c | Should -BeTrue
        }
        It "in fails when value not in list" {
            $c = [PSCustomObject]@{ field = "project_id"; op = "in"; value = @(1, 2, 3) }
            Test-Condition -Payload (New-Payload -ProjectId 9) -Condition $c | Should -BeFalse
        }
        It "not_in passes when value not in list" {
            $c = [PSCustomObject]@{ field = "project_id"; op = "not_in"; value = @(1, 2, 3) }
            Test-Condition -Payload (New-Payload -ProjectId 9) -Condition $c | Should -BeTrue
        }
        It "not_in fails when value is in list" {
            $c = [PSCustomObject]@{ field = "project_id"; op = "not_in"; value = @(1, 2, 3) }
            Test-Condition -Payload (New-Payload -ProjectId 2) -Condition $c | Should -BeFalse
        }
    }

    Context "Unknown operator" {
        It "returns false for unrecognized operator" {
            Test-Condition -Payload (New-Payload) -Condition (New-Condition "priority" "~=" 1) | Should -BeFalse
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Resolve-MatchingProviders
# ══════════════════════════════════════════════════════════════════════════════

Describe "Resolve-MatchingProviders" {

    Context "Catch-all (empty conditions)" {
        It "matches every payload" {
            $config = New-Config `
                -Providers @(@{ name = "d1"; plugin = "discord"; options = @{ webhook_url = "http://x" } }) `
                -Rules     @(@{ name = "Catch-all"; providers = @("d1"); conditions = $null })

            $result = Resolve-MatchingProviders -Payload (New-Payload) -Config $config
            $result.Count | Should -Be 1
            $result[0].InstanceName | Should -Be "d1"
        }
    }

    Context "match = all (AND)" {
        It "matches when ALL conditions pass" {
            $config = New-Config `
                -Providers @(@{ name = "d1"; plugin = "discord"; options = @{} }) `
                -Rules @(@{
                    name       = "High prio project 1"
                    match      = "all"
                    providers  = @("d1")
                    conditions = @(
                        @{ field = "priority"; op = ">="; value = 3 }
                        @{ field = "project_id"; op = "="; value = 1 }
                    )
                })

            $p = New-Payload -Priority 4 -ProjectId 1
            $result = Resolve-MatchingProviders -Payload $p -Config $config
            $result.Count | Should -Be 1
        }

        It "does NOT match when any condition fails" {
            $config = New-Config `
                -Providers @(@{ name = "d1"; plugin = "discord"; options = @{} }) `
                -Rules @(@{
                    name       = "High prio project 1"
                    match      = "all"
                    providers  = @("d1")
                    conditions = @(
                        @{ field = "priority"; op = ">="; value = 3 }
                        @{ field = "project_id"; op = "="; value = 1 }
                    )
                })

            # priority passes but project_id fails
            $p = New-Payload -Priority 4 -ProjectId 2
            $result = Resolve-MatchingProviders -Payload $p -Config $config
            $result.Count | Should -Be 0
        }
    }

    Context "match = any (OR)" {
        It "matches when at least one condition passes" {
            $config = New-Config `
                -Providers @(@{ name = "d1"; plugin = "discord"; options = @{} }) `
                -Rules @(@{
                    name       = "Either condition"
                    match      = "any"
                    providers  = @("d1")
                    conditions = @(
                        @{ field = "priority"; op = "="; value = 5 }
                        @{ field = "is_favorite"; op = "="; value = $true }
                    )
                })

            # only is_favorite matches
            $p = New-Payload -Priority 1 -IsFavorite $true
            $result = Resolve-MatchingProviders -Payload $p -Config $config
            $result.Count | Should -Be 1
        }

        It "does NOT match when no condition passes" {
            $config = New-Config `
                -Providers @(@{ name = "d1"; plugin = "discord"; options = @{} }) `
                -Rules @(@{
                    name       = "Either condition"
                    match      = "any"
                    providers  = @("d1")
                    conditions = @(
                        @{ field = "priority"; op = "="; value = 5 }
                        @{ field = "is_favorite"; op = "="; value = $true }
                    )
                })

            $p = New-Payload -Priority 1 -IsFavorite $false
            $result = Resolve-MatchingProviders -Payload $p -Config $config
            $result.Count | Should -Be 0
        }
    }

    Context "stop_on_match" {
        It "stops after first matching rule when stop_on_match is true" {
            $config = New-Config `
                -Providers @(
                @{ name = "d1"; plugin = "discord"; options = @{} }
                @{ name = "d2"; plugin = "discord"; options = @{} }
            ) `
                -Rules @(
                @{ name = "First"; providers = @("d1"); conditions = $null; stop_on_match = $true }
                @{ name = "Second"; providers = @("d2"); conditions = $null; stop_on_match = $false }
            )

            $result = Resolve-MatchingProviders -Payload (New-Payload) -Config $config
            $result.Count | Should -Be 1
            $result[0].InstanceName | Should -Be "d1"
        }

        It "continues evaluating rules when stop_on_match is false" {
            $config = New-Config `
                -Providers @(
                @{ name = "d1"; plugin = "discord"; options = @{} }
                @{ name = "d2"; plugin = "discord"; options = @{} }
            ) `
                -Rules @(
                @{ name = "First"; providers = @("d1"); conditions = $null; stop_on_match = $false }
                @{ name = "Second"; providers = @("d2"); conditions = $null; stop_on_match = $false }
            )

            $result = Resolve-MatchingProviders -Payload (New-Payload) -Config $config
            $result.Count | Should -Be 2
        }
    }

    Context "Provider deduplication" {
        It "invokes a provider instance only once even if matched by multiple rules" {
            $config = New-Config `
                -Providers @(@{ name = "d1"; plugin = "discord"; options = @{} }) `
                -Rules @(
                @{ name = "Rule A"; providers = @("d1"); conditions = $null }
                @{ name = "Rule B"; providers = @("d1"); conditions = $null }
            )

            $result = Resolve-MatchingProviders -Payload (New-Payload) -Config $config
            $result.Count | Should -Be 1
        }
    }

    Context "Unknown provider reference" {
        It "skips unknown provider and does not crash" {
            $config = New-Config `
                -Providers @(@{ name = "d1"; plugin = "discord"; options = @{} }) `
                -Rules @(@{ name = "Bad rule"; providers = @("nonexistent"); conditions = $null })

            $result = Resolve-MatchingProviders -Payload (New-Payload) -Config $config
            $result.Count | Should -Be 0
        }
    }

    Context "Options are passed through" {
        It "converts provider options to a hashtable accessible by key" {
            $config = New-Config `
                -Providers @(@{ name = "d1"; plugin = "discord"; options = @{ webhook_url = "https://example.com" } }) `
                -Rules @(@{ name = "Catch-all"; providers = @("d1"); conditions = $null })

            $result = Resolve-MatchingProviders -Payload (New-Payload) -Config $config
            $result[0].Options["webhook_url"] | Should -Be "https://example.com"
        }
    }

    Context "No rules match" {
        It "returns an empty list when no rule matches" {
            $config = New-Config `
                -Providers @(@{ name = "d1"; plugin = "discord"; options = @{} }) `
                -Rules @(
                @{ name = "High priority only"; providers = @("d1"); conditions = @(@{ field = "priority"; op = "="; value = 5 }) }
            )

            $p = New-Payload -Priority 1
            $result = Resolve-MatchingProviders -Payload $p -Config $config
            $result.Count | Should -Be 0
        }
    }

    Context "Multiple providers in one rule" {
        It "returns all provider instances when a single rule references multiple" {
            $config = New-Config `
                -Providers @(
                @{ name = "d1"; plugin = "discord"; options = @{} }
                @{ name = "d2"; plugin = "discord"; options = @{} }
            ) `
                -Rules @(@{ name = "Both"; providers = @("d1", "d2"); conditions = $null })

            $result = Resolve-MatchingProviders -Payload (New-Payload) -Config $config
            $result.Count | Should -Be 2
            $result.InstanceName | Should -Contain "d1"
            $result.InstanceName | Should -Contain "d2"
        }

        It "lowercases the plugin name in returned entries" {
            $config = New-Config `
                -Providers @(@{ name = "d1"; plugin = "Discord"; options = @{} }) `
                -Rules @(@{ name = "Catch-all"; providers = @("d1"); conditions = $null })

            $result = Resolve-MatchingProviders -Payload (New-Payload) -Config $config
            $result[0].PluginName | Should -Be "discord"
        }
    }

    Context "stop_on_match only stops when the rule actually matched" {
        It "evaluates later rules when the first stop_on_match rule did not match" {
            $config = New-Config `
                -Providers @(
                @{ name = "d1"; plugin = "discord"; options = @{} }
                @{ name = "d2"; plugin = "discord"; options = @{} }
            ) `
                -Rules @(
                @{ name = "Never matches"; stop_on_match = $true; providers = @("d1"); conditions = @(@{ field = "priority"; op = "="; value = 99 }) }
                @{ name = "Always matches"; stop_on_match = $false; providers = @("d2"); conditions = $null; }
            )

            $result = Resolve-MatchingProviders -Payload (New-Payload -Priority 1) -Config $config
            $result.Count | Should -Be 1
            $result[0].InstanceName | Should -Be "d2"
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Invoke-Providers
# ══════════════════════════════════════════════════════════════════════════════

Describe "Invoke-Providers" {

    BeforeEach {
        Clear-PluginRegistry
    }

    It "returns 1 when plugin returns true" {
        Register-Plugin -Name "test" -ScriptBlock { param($p, $o) return $true }
        $list = New-ProviderList -InstanceName "t1" -PluginName "test"
        Invoke-Providers -Payload (New-Payload) -ProviderList $list | Should -Be 1
    }

    It "returns 0 when plugin returns false" {
        Register-Plugin -Name "test" -ScriptBlock { param($p, $o) return $false }
        $list = New-ProviderList -InstanceName "t1" -PluginName "test"
        Invoke-Providers -Payload (New-Payload) -ProviderList $list | Should -Be 0
    }

    It "returns 0 and does not crash when plugin throws" {
        Register-Plugin -Name "test" -ScriptBlock { param($p, $o) throw "boom" }
        $list = New-ProviderList -InstanceName "t1" -PluginName "test"
        Invoke-Providers -Payload (New-Payload) -ProviderList $list | Should -Be 0
    }

    It "skips and returns 0 for unknown plugin name" {
        $list = New-ProviderList -InstanceName "t1" -PluginName "doesNotExist"
        Invoke-Providers -Payload (New-Payload) -ProviderList $list | Should -Be 0
    }

    It "counts each successful provider independently" {
        Register-Plugin -Name "ok"   -ScriptBlock { param($p, $o) return $true }
        Register-Plugin -Name "fail" -ScriptBlock { param($p, $o) return $false }

        $list = [System.Collections.Generic.List[hashtable]]::new()
        $list.Add(@{ InstanceName = "p1"; PluginName = "ok"; Options = @{} })
        $list.Add(@{ InstanceName = "p2"; PluginName = "fail"; Options = @{} })
        $list.Add(@{ InstanceName = "p3"; PluginName = "ok"; Options = @{} })

        Invoke-Providers -Payload (New-Payload) -ProviderList $list | Should -Be 2
    }

    It "passes Options hashtable to plugin" {
        $receivedOptions = $null
        Register-Plugin -Name "test" -ScriptBlock {
            param($p, $o)
            $script:receivedOptions = $o
            return $true
        }
        $opts = @{ webhook_url = "https://example.com"; token = "abc" }
        $list = New-ProviderList -InstanceName "t1" -PluginName "test" -Options $opts
        Invoke-Providers -Payload (New-Payload) -ProviderList $list | Out-Null
        $script:receivedOptions["webhook_url"] | Should -Be "https://example.com"
    }

    It "passes Payload to plugin" {
        $receivedPayload = $null
        Register-Plugin -Name "test" -ScriptBlock {
            param($p, $o)
            $script:receivedPayload = $p
            return $true
        }
        $payload = New-Payload -TaskId 99 -TaskTitle "My Task"
        $list = New-ProviderList -InstanceName "t1" -PluginName "test"
        Invoke-Providers -Payload $payload -ProviderList $list | Out-Null
        $script:receivedPayload.TaskId    | Should -Be 99
        $script:receivedPayload.TaskTitle | Should -Be "My Task"
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Register-Plugin / Clear-PluginRegistry
# ══════════════════════════════════════════════════════════════════════════════

Describe "Register-Plugin and Clear-PluginRegistry" {

    BeforeEach { Clear-PluginRegistry }

    It "registers a plugin by lowercase name" {
        Register-Plugin -Name "Discord" -ScriptBlock { $true }
        (Get-RegisteredPlugins).ContainsKey("discord") | Should -BeTrue
    }

    It "name is stored lowercase regardless of input casing" {
        Register-Plugin -Name "SLACK" -ScriptBlock { $true }
        (Get-RegisteredPlugins).ContainsKey("slack")  | Should -BeTrue
        (Get-RegisteredPlugins).ContainsKey("SLACK")  | Should -BeFalse
    }

    It "overwrites an existing registration with the same name" {
        Register-Plugin -Name "test" -ScriptBlock { return "first" }
        Register-Plugin -Name "test" -ScriptBlock { return "second" }
        (Get-RegisteredPlugins).Count | Should -Be 1
    }

    It "Clear-PluginRegistry removes all registrations" {
        Register-Plugin -Name "a" -ScriptBlock { $true }
        Register-Plugin -Name "b" -ScriptBlock { $true }
        Clear-PluginRegistry
        (Get-RegisteredPlugins).Count | Should -Be 0
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Build-Payload
# ══════════════════════════════════════════════════════════════════════════════

Describe "Build-Payload" {

    BeforeAll {
        $script:Tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Europe/Warsaw")
        $script:Utc = [System.TimeZoneInfo]::Utc

        # Minimal raw task object as returned by the API
        $script:RawTask = [PSCustomObject]@{
            id           = 42
            title        = "Test reminder"
            description  = "Do the thing"
            project_id   = 7
            done         = $false
            priority     = 3
            percent_done = 50
            is_favorite  = $true
            attachments  = @("file1.pdf")
            labels       = @([PSCustomObject]@{ id = 1; title = "label1" }, [PSCustomObject]@{ id = 2; title = "label2" })
            assignees    = @("alan")
        }

        $script:ReminderUtc = [datetime]::new(2026, 2, 22, 21, 0, 0, [System.DateTimeKind]::Utc)
    }

    It "maps TaskId correctly" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://localhost:3456"
        $p.TaskId | Should -Be 42
    }

    It "maps TaskTitle correctly" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://localhost:3456"
        $p.TaskTitle | Should -Be "Test reminder"
    }

    It "builds TaskUrl from PublicBaseUrl and task id" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://localhost:3456"
        $p.TaskUrl | Should -Be "http://localhost:3456/tasks/42"
    }

    It "trims trailing slash from PublicBaseUrl" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://localhost:3456/"
        $p.TaskUrl | Should -Be "http://localhost:3456/tasks/42"
    }

    It "maps ProjectId" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.ProjectId | Should -Be 7
    }

    It "maps Priority" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.Priority | Should -Be 3
    }

    It "maps PercentDone" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.PercentDone | Should -Be 50
    }

    It "maps IsFavorite" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.IsFavorite | Should -BeTrue
    }

    It "sets HasAttachments to true when attachments exist" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.HasAttachments | Should -BeTrue
    }

    It "sets HasAttachments to false when attachments is null" {
        $task = $script:RawTask.PSObject.Copy()
        $task.attachments = $null
        $p = Build-Payload -Task $task -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.HasAttachments | Should -BeFalse
    }

    It "counts labels correctly" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.LabelCount | Should -Be 2
    }

    It "maps Labels titles array" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.Labels[0].title | Should -Be "label1"
        $p.Labels[0].id | Should -Be 1
        $p.Labels[1].title | Should -Be "label2"
        $p.Labels[1].id | Should -Be 2
    }

    It "returns LabelCount 0 when labels is null" {
        $task = $script:RawTask.PSObject.Copy()
        $task.labels = $null
        $p = Build-Payload -Task $task -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.LabelCount | Should -Be 0
    }

    It "counts assignees correctly" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.AssigneeCount | Should -Be 1
    }

    It "returns AssigneeCount 0 when assignees is null" {
        $task = $script:RawTask.PSObject.Copy()
        $task.assignees = $null
        $p = Build-Payload -Task $task -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.AssigneeCount | Should -Be 0
    }

    It "stores ReminderUtc unchanged" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.ReminderUtc | Should -Be $script:ReminderUtc
    }

    It "converts ReminderLocal to the given timezone (Warsaw = UTC+1 in winter)" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Tz -PublicBaseUrl "http://x"
        # 21:00 UTC -> 22:00 Warsaw (CET = UTC+1)
        $p.ReminderLocal.Hour | Should -Be 22
    }

    It "formats ReminderStr with offset string" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Tz -PublicBaseUrl "http://x"
        $p.ReminderStr | Should -Match 'UTC\+01:00'
    }

    It "includes Timezone object in payload" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Tz -PublicBaseUrl "http://x"
        $p.Timezone.Id | Should -Be "Europe/Warsaw"
    }

    It "maps Done when false" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.Done | Should -BeFalse
    }

    It "maps Done when true" {
        $task = $script:RawTask.PSObject.Copy()
        $task.done = $true
        $p = Build-Payload -Task $task -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.Done | Should -BeTrue
    }

    It "maps Description" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.Description | Should -Be "Do the thing"
    }

    It "sets HasAttachments to false when attachments is an empty array" {
        $task = $script:RawTask.PSObject.Copy()
        $task.attachments = @()
        $p = Build-Payload -Task $task -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.HasAttachments | Should -BeFalse
    }

    It "returns LabelCount 0 when labels is an empty array" {
        $task = $script:RawTask.PSObject.Copy()
        $task.labels = @()
        $p = Build-Payload -Task $task -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.LabelCount | Should -Be 0
    }

    It "returns AssigneeCount 0 when assignees is an empty array" {
        $task = $script:RawTask.PSObject.Copy()
        $task.assignees = @()
        $p = Build-Payload -Task $task -ReminderUtc $script:ReminderUtc -Tz $script:Utc -PublicBaseUrl "http://x"
        $p.AssigneeCount | Should -Be 0
    }

    It "ReminderStr includes the formatted local date and time" {
        $p = Build-Payload -Task $script:RawTask -ReminderUtc $script:ReminderUtc -Tz $script:Tz -PublicBaseUrl "http://x"
        # 21:00 UTC -> 22:00 Warsaw (CET = UTC+1 in February)
        $p.ReminderStr | Should -Match '^2026-02-22 22:00'
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Import-RulesConfig
# ══════════════════════════════════════════════════════════════════════════════

Describe "Import-RulesConfig" {

    BeforeAll {
        $script:TempDir = Join-Path $TestDrive "config"
        New-Item -ItemType Directory -Path $script:TempDir | Out-Null
    }

    It "parses a valid rules.json" {
        $json = '{ "providers": { "d1": { "plugin": "discord", "options": {} } }, "rules": [] }'
        $path = Join-Path $script:TempDir "valid.json"
        $json | Set-Content $path
        $config = Import-RulesConfig -Path $path
        $config.providers.PSObject.Properties.Name | Should -Contain "d1"
    }

    It "throws when file does not exist" {
        { Import-RulesConfig -Path (Join-Path $script:TempDir "missing.json") } | Should -Throw
    }

    It "throws on malformed JSON" {
        $path = Join-Path $script:TempDir "bad.json"
        "{ not valid json" | Set-Content $path
        { Import-RulesConfig -Path $path } | Should -Throw
    }

    It "throws when providers key is missing" {
        $json = '{ "rules": [] }'
        $path = Join-Path $script:TempDir "noproviders.json"
        $json | Set-Content $path
        { Import-RulesConfig -Path $path } | Should -Throw
    }

    It "throws when rules key is missing" {
        $json = '{ "providers": {} }'
        $path = Join-Path $script:TempDir "norules.json"
        $json | Set-Content $path
        { Import-RulesConfig -Path $path } | Should -Throw
    }

    It "succeeds when providers is an empty object and rules is an empty array" {
        $json = '{ "providers": {}, "rules": [] }'
        $path = Join-Path $script:TempDir "empty-valid.json"
        $json | Set-Content $path
        { Import-RulesConfig -Path $path } | Should -Not -Throw
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Get-FiredReminders
# ══════════════════════════════════════════════════════════════════════════════

Describe "Get-FiredReminders" {

    BeforeAll {
        $script:FiredDir = Join-Path $TestDrive "state"
        New-Item -ItemType Directory -Path $script:FiredDir | Out-Null
    }

    It "returns an empty HashSet when the file does not exist" {
        $path = Join-Path $script:FiredDir "nonexistent.json"
        $set = Get-FiredReminders -Path $path
        ($set -is [System.Collections.Generic.HashSet[string]]) | Should -BeTrue
        $set.Count | Should -Be 0
    }

    It "loads all keys from a valid JSON array file" {
        $path = Join-Path $script:FiredDir "valid.json"
        '["key1","key2","key3"]' | Set-Content $path
        $set = Get-FiredReminders -Path $path
        $set.Count | Should -Be 3
        $set.Contains("key1") | Should -BeTrue
        $set.Contains("key2") | Should -BeTrue
        $set.Contains("key3") | Should -BeTrue
    }

    It "returns an empty set and does not throw when the file contains invalid JSON" {
        $path = Join-Path $script:FiredDir "corrupt.json"
        "{ not valid json" | Set-Content $path
        { Get-FiredReminders -Path $path } | Should -Not -Throw
        $set = Get-FiredReminders -Path $path
        $set.Count | Should -Be 0
    }

    It "deduplicates keys that appear more than once in the JSON array" {
        $path = Join-Path $script:FiredDir "dupes.json"
        '["a","a","b"]' | Set-Content $path
        $set = Get-FiredReminders -Path $path
        $set.Count | Should -Be 2
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Save-FiredReminders
# ══════════════════════════════════════════════════════════════════════════════

Describe "Save-FiredReminders" {

    BeforeAll {
        $script:SaveDir = Join-Path $TestDrive "save-state"
        New-Item -ItemType Directory -Path $script:SaveDir | Out-Null
    }

    It "writes a JSON file that Get-FiredReminders can read back (round-trip)" {
        $path = Join-Path $script:SaveDir "roundtrip.json"
        $set = [System.Collections.Generic.HashSet[string]]::new()
        $set.Add("task:1:2026-01-01T00:00:00") | Out-Null
        $set.Add("task:2:2026-01-02T00:00:00") | Out-Null
        Save-FiredReminders -Set $set -Path $path

        $loaded = Get-FiredReminders -Path $path
        $loaded.Count | Should -Be 2
        $loaded.Contains("task:1:2026-01-01T00:00:00") | Should -BeTrue
        $loaded.Contains("task:2:2026-01-02T00:00:00") | Should -BeTrue
    }

    It "truncates to the last 2000 entries when the set exceeds 2000" {
        $path = Join-Path $script:SaveDir "truncate.json"
        $set = [System.Collections.Generic.HashSet[string]]::new()
        for ($i = 1; $i -le 2500; $i++) { $set.Add("key-$i") | Out-Null }

        Save-FiredReminders -Set $set -Path $path

        $loaded = Get-FiredReminders -Path $path
        $loaded.Count | Should -Be 2000
    }
}
