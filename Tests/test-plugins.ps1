# test-plugins.ps1
#
# Local integration-test harness for notification plugins.
# Builds a realistic Payload from a hardcoded sample task and fires it — no Docker, no running app, no API.
#
# ── USAGE ─────────────────────────────────────────────────────────────────────
#   pwsh -File test-plugins.ps1 -Options @{ webhook_url = "https://..." }
#       Run every loaded plugin
#
#   pwsh -File test-plugins.ps1 -Plugin discord -Options @{ webhook_url = "https://..." }
#       Test discord with an explicit webhook URL (overrides env var).
#
# ── PARAMETERS ────────────────────────────────────────────────────────────────
#   -Plugin        Plugin name to target (default: all loaded plugins)
#   -Options       Options hashtable passed to the plugin (e.g. webhook URLs, API keys).
#   -PublicBaseUrl Base URL for task links      (default: http://localhost:3456)
#   -Timezone      Windows/IANA timezone ID     (default: UTC)
#   -PluginsDir    Location of notification-*.ps1 files (default: ./plugins)

param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]    $Plugin        = "",
    [Parameter(Mandatory = $true, Position = 1)]
    [hashtable] $Options       = @{},
    [string]    $PublicBaseUrl = ($env:VIKUNJA_PUBLIC_URL ?? "http://localhost:3456"),
    [string]    $Timezone      = ($env:TZ              ?? "UTC"),
    [string]    $PluginsDir    = (Join-Path (Split-Path $PSScriptRoot -Parent) "plugins")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    Push-Location $PSScriptRoot

    # Import the engine module from the repo root
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) "ReminderEngine.psm1"
    Import-Module $modulePath -Force

    # ── Hardcoded sample task ─────────────────────────────────────────────────────
    # Mirrors a real Vikunja API task response.
    $samplePath = Join-Path $PSScriptRoot 'sample-data.json'
    if (-not (Test-Path $samplePath)) {
        throw "[harness] sample-data.json not found at $samplePath"
    }
    $tasks = Get-Content $samplePath -Raw | ConvertFrom-Json

    # ── Load plugins ───────────────────────────────────────────────────────────────

    Write-Host ""
    Write-Host "======================================================"
    Write-Host " Vikunja Plugin Integration Harness"
    Write-Host "  Plugins dir  : $PluginsDir"
    Write-Host "  Public URL   : $PublicBaseUrl"
    Write-Host "  Timezone     : $Timezone"
    Write-Host "======================================================"

    $pluginFiles = @(Get-ChildItem -Path $PluginsDir -Filter "notification-*.ps1" -ErrorAction SilentlyContinue)
    if ($pluginFiles.Count -eq 0) {
        Write-Error "No notification plugins found in '$PluginsDir'."
        exit 1
    }

    foreach ($file in $pluginFiles) {
        Write-Host "[harness] Loading $($file.Name)..."
        . $file.FullName
    }

    $registered = Get-RegisteredPlugins
    Write-Host "[harness] $($registered.Count) plugin(s) registered: $($registered.Keys -join ', ')"

    # ── Resolve timezone ───────────────────────────────────────────────────────────

    try {
        $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($Timezone)
    }
    catch {
        Write-Warning "[harness] Unknown timezone '$Timezone' — falling back to UTC."
        $tz = [System.TimeZoneInfo]::Utc
    }

    # ── Build payload ──────────────────────────────────────────────────────────────

    $task = $tasks  | Select-Object -First 1
    $reminderUtc = [datetime]::Parse(
        $task.reminders[0].reminder,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    )

    $payload = Build-Payload -Task $task -ReminderUtc $reminderUtc -Tz $tz -PublicBaseUrl $PublicBaseUrl

    Write-Host ""
    Write-Host "[harness] Payload:"
    Write-Host "  TaskId       : $($payload.TaskId)"
    Write-Host "  TaskTitle    : $($payload.TaskTitle)"
    Write-Host "  TaskUrl      : $($payload.TaskUrl)"
    Write-Host "  ReminderStr  : $($payload.ReminderStr)"
    Write-Host "  Priority     : $($payload.Priority)"
    Write-Host "  Done         : $($payload.Done)"
    Write-Host "  ProjectId    : $($payload.ProjectId)"
    Write-Host "  Labels       : $($payload.Labels.title -join ', ')"`
        Write-Host "  Attachments  : $($payload.HasAttachments)"

}
catch {
    Write-Error "[harness] Failed: $_"
    exit 1
}
finally {
    Pop-Location
}

# ── Fire ───────────────────────────────────────────────────────────────────────

$pluginsToTest = if ($Plugin) { @($Plugin.ToLower()) } else { @($registered.Keys) }

$results = [ordered]@{}

foreach ($pluginName in ($pluginsToTest | Sort-Object)) {
    if (-not $registered.ContainsKey($pluginName)) {
        Write-Warning "[harness] Plugin '$pluginName' is not registered — skipping."
        $results[$pluginName] = "NOT FOUND"
        continue
    }

    $effectiveOpts = @{}
    foreach ($kv in $Options.GetEnumerator()) { $effectiveOpts[$kv.Key] = $kv.Value }

    Write-Host ""
    Write-Host "── Plugin: $pluginName $(if ($effectiveOpts.Count -eq 0) { '(no options)' } else { "(options: $($effectiveOpts.Keys -join ', '))" }) ──" -ForegroundColor Yellow

    $list = [System.Collections.Generic.List[hashtable]]::new()
    $list.Add(@{ InstanceName = "test-$pluginName"; PluginName = $pluginName; Options = $effectiveOpts })

    $ok = Invoke-Providers -Payload $payload -ProviderList $list
    $results[$pluginName] = if ($ok -gt 0) { "PASS" } else { "FAIL" }
}

# ── Summary ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "======================================================"
Write-Host " Results"
Write-Host "======================================================"
foreach ($kv in $results.GetEnumerator()) {
    $color = switch ($kv.Value) {
        "PASS"      { "Green" }
        "FAIL"      { "Red"   }
        default     { "Yellow" }
    }
    Write-Host ("  {0,-14} {1}" -f $kv.Key, $kv.Value) -ForegroundColor $color
}
Write-Host ""
