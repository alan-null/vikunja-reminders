# Vikunja Reminder Agent — entrypoint

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Import engine -------------------------------------------------------------

$enginePath = Join-Path $PSScriptRoot "ReminderEngine.psm1"
Import-Module $enginePath -Force

# -- Configuration -------------------------------------------------------------

$ApiUrl = $env:VIKUNJA_API_URL ?? "http://host.docker.internal:3456/api/v1"
$ApiToken = $env:VIKUNJA_API_TOKEN
$CheckInterval = [int]($env:CHECK_INTERVAL_SECONDS ?? 60)
$NotifyBeforeSecs = [int]($env:NOTIFY_BEFORE_SECONDS ?? 0)
$PublicBaseUrl = ($env:VIKUNJA_PUBLIC_URL ?? ($ApiUrl -replace '/api/v1$', '')).TrimEnd('/')
$PluginsDir = $env:PLUGINS_DIR ?? "/plugins"
$ConfigFile = $env:CONFIG_FILE ?? "/config/rules.json"
$StateFile = "/state/fired_reminders.json"


if (-not $ApiToken) { Write-Error "VIKUNJA_API_TOKEN is not set." ; exit 1 }

# -- API helpers ---------------------------------------------------------------

function Get-ApiHeaders {
    @{ "Authorization" = "Bearer $ApiToken" ; "Content-Type" = "application/json" }
}

function Get-UserTimezone {
    try {
        $user = Invoke-RestMethod -Uri "$ApiUrl/user" -Headers (Get-ApiHeaders) -Method Get
        $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($user.settings.timezone)
        Write-Host "  Timezone       : $($tz.Id)"
        return $tz
    }
    catch {
        Write-Warning "Could not resolve user timezone, falling back to UTC. Error: $_"
        return [System.TimeZoneInfo]::Utc
    }
}

function Get-UpcomingTasks {
    $filter = "done = false && reminders >= now-${CheckInterval}s && reminders <= now+$($NotifyBeforeSecs + 5)s"
    $encoded = [Uri]::EscapeDataString($filter)
    $url = "$ApiUrl/tasks?filter=$encoded&per_page=500"
    Write-Host "  Filter         : $filter"
    try {
        $response = Invoke-RestMethod -Uri $url -Headers (Get-ApiHeaders) -Method Get
        Write-Output $response -NoEnumerate
    }
    catch {
        Write-Warning "Failed to fetch tasks: $_"
        return @()
    }
}

# -- Main -----------------------------------------------------------------

Write-Host "======================================================"
Write-Host " Vikunja Reminder Agent"
Write-Host "  API URL        : $ApiUrl"
Write-Host "  Public URL     : $PublicBaseUrl"
Write-Host "  Check interval : ${CheckInterval}s"
Write-Host "  Notify before  : ${NotifyBeforeSecs}s"
Write-Host "  Plugins dir    : $PluginsDir"
Write-Host "  Config file    : $ConfigFile"
Write-Host "======================================================"

$pluginFiles = @(Get-ChildItem -Path $PluginsDir -Filter "notification-*.ps1" -ErrorAction SilentlyContinue)
if ($pluginFiles.Count -eq 0) {
    Write-Error "No notification plugins found in '$PluginsDir'."
    exit 1
}
foreach ($file in $pluginFiles) {
    Write-Host "  [plugin] Loading $($file.Name)..."
    . $file.FullName
}
$registeredPlugins = Get-RegisteredPlugins
Write-Host "  $($registeredPlugins.Count) plugin(s) loaded: $($registeredPlugins.Keys -join ', ')"

$rulesConfig = Import-RulesConfig -Path $ConfigFile
$firedReminders = Get-FiredReminders -Path $StateFile
$userTimezone = Get-UserTimezone

Write-Host "======================================================"

# -- Main loop -----------------------------------------------------------------

while ($true) {
    $now = [datetime]::UtcNow
    $fireFrom = $now.AddSeconds(-$CheckInterval)
    $fireBefore = $now.AddSeconds($NotifyBeforeSecs + 5)

    Write-Host ""
    $nowLocal = [System.TimeZoneInfo]::ConvertTimeFromUtc($now, $userTimezone)
    $fireFromLocal = [System.TimeZoneInfo]::ConvertTimeFromUtc($fireFrom, $userTimezone)
    $fireBeforeLocal = [System.TimeZoneInfo]::ConvertTimeFromUtc($fireBefore, $userTimezone)
    Write-Host "[$($nowLocal.ToString('HH:mm:ss'))] Polling | window $($fireFromLocal.ToString('HH:mm:ss')) -> $($fireBeforeLocal.ToString('HH:mm:ss')) $($userTimezone.Id)"

    $tasks = Get-UpcomingTasks

    if ($tasks.Count -eq 0) {
        Write-Host "  No tasks with reminders in this window."
    }

    foreach ($task in $tasks) {
        if ($task.done) { continue }

        foreach ($reminder in $task.reminders) {
            $reminderTime = [datetime]::Parse(
                $reminder.reminder,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind -bor
                [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
            )

            $reminderLocal = [System.TimeZoneInfo]::ConvertTimeFromUtc($reminderTime, $userTimezone)

            if ($reminderTime -lt $fireFrom -or $reminderTime -gt $fireBefore) { continue }

            $stateKey = "$($task.id)::$($reminder.reminder)"
            if ($firedReminders.Contains($stateKey)) {
                Write-Host "  Skipped (already fired): task #$($task.id) @ $($reminderLocal.ToString('yyyy-MM-dd HH:mm:ss')) $($userTimezone.Id)"
                continue
            }

            Write-Host "  Firing: task #$($task.id) '$($task.title)' @ $($reminderLocal.ToString('yyyy-MM-dd HH:mm:ss')) $($userTimezone.Id)"

            $payload = Build-Payload -Task $task -ReminderUtc $reminderTime -Tz $userTimezone -PublicBaseUrl $PublicBaseUrl
            $providers = Resolve-MatchingProviders -Payload $payload -Config $rulesConfig

            if ($providers.Count -eq 0) {
                Write-Host "  [rules] No providers matched — reminder will not be sent."
            }

            $sent = Invoke-Providers -Payload $payload -ProviderList $providers

            if ($sent -gt 0) {
                $firedReminders.Add($stateKey) | Out-Null
                Save-FiredReminders -Set $firedReminders -Path $StateFile
            }
        }
    }

    Start-Sleep -Seconds $CheckInterval
}
