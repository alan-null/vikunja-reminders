# notification-debug.ps1
#
# Simple debug plugin for Vikunja Reminder Agent.
#
# Prints the received `$Payload` and `$Options` to the console and returns $true.
#
# See example output at the end of this file.

Register-Plugin -Name "debug" -ScriptBlock {
    param(
        [hashtable] $Payload,
        [hashtable] $Options
    )

    Write-Host "  [debug] Invoked: task #$($Payload.TaskId) '$($Payload.TaskTitle)'"

    Write-Host "    Options:"
    if ($Options -and $Options.Count -gt 0) {
        foreach ($k in $Options.Keys) {
            Write-Host "      $k = $($Options[$k])"
        }
    }
    else { Write-Host "      (none)" }

    Write-Host "  [debug] Payload raw object:"
    $Payload.GetEnumerator() | Sort-Object Key | ForEach-Object {
        Write-Host ("    {0,-20} = {1}" -f $_.Key, $_.Value)
    }
    return $true
}

# Example output:
# # ======================================================
# Attaching to vikunja-reminder-agent-1
# vikunja-reminder-agent-1  | ======================================================
# vikunja-reminder-agent-1  |  Vikunja Reminder Agent
# vikunja-reminder-agent-1  |   API URL        : http://host.docker.internal:3456/api/v1
# vikunja-reminder-agent-1  |   Public URL     : http://localhost:3456
# vikunja-reminder-agent-1  |   Check interval : 5s
# vikunja-reminder-agent-1  |   Notify before  : 600s
# vikunja-reminder-agent-1  |   Plugins dir    : ./plugins
# vikunja-reminder-agent-1  |   Config file    : ./config/rules.json
# vikunja-reminder-agent-1  | ======================================================
# vikunja-reminder-agent-1  |   [plugin] Loading notification-debug.ps1...
# vikunja-reminder-agent-1  |   [plugin] Registered: debug
# vikunja-reminder-agent-1  |   [plugin] Loading notification-discord.ps1...
# vikunja-reminder-agent-1  |   [plugin] Registered: discord
# vikunja-reminder-agent-1  |   2 plugin(s) loaded: debug, discord
# vikunja-reminder-agent-1  |   Timezone       : Europe/Warsaw
# vikunja-reminder-agent-1  | ======================================================
# vikunja-reminder-agent-1  |
# vikunja-reminder-agent-1  | [18:17:26] Polling | window 18:17:21 -> 18:27:31 Europe/Warsaw
# vikunja-reminder-agent-1  |   Filter         : done = false && reminders >= now-5s && reminders <= now+605s
# vikunja-reminder-agent-1  |   No tasks with reminders in this window.
# vikunja-reminder-agent-1  |
# vikunja-reminder-agent-1  | [18:17:41] Polling | window 18:17:36 -> 18:27:46 Europe/Warsaw
# vikunja-reminder-agent-1  |   Filter         : done = false && reminders >= now-5s && reminders <= now+605s
# vikunja-reminder-agent-1  |   Firing: task #1 'ExampleTask' @ 2026-02-22 18:25:00 Europe/Warsaw
# vikunja-reminder-agent-1  |   [rules] Matched rule: 'Catch-all — every reminder'
# vikunja-reminder-agent-1  | WARNING:   [rules] Unknown provider 'slack-team' referenced in rule 'Catch-all — every reminder' — kipping.
# vikunja-reminder-agent-1  |   [debug] Invoked: task #1 'ExampleTask'
# vikunja-reminder-agent-1  |     Options:
# vikunja-reminder-agent-1  |       channel = CH1
# vikunja-reminder-agent-1  |   [debug] Payload raw object:
# vikunja-reminder-agent-1  |     AssigneeCount        = 0
# vikunja-reminder-agent-1  |     Description          = <p>This is <strong>awesome!!</strong></p>
# vikunja-reminder-agent-1  |     Done                 = False
# vikunja-reminder-agent-1  |     HasAttachments       = True
# vikunja-reminder-agent-1  |     IsFavorite           = False
# vikunja-reminder-agent-1  |     LabelCount           = 3
# vikunja-reminder-agent-1  |     Labels               = System.Object[]
# vikunja-reminder-agent-1  |     PercentDone          = 0
# vikunja-reminder-agent-1  |     Priority             = 4
# vikunja-reminder-agent-1  |     ProjectId            = 1
# vikunja-reminder-agent-1  |     ReminderLocal        = 2/22/2026 6:25:00 PM
# vikunja-reminder-agent-1  |     ReminderStr          = 2026-02-22 18:25  (UTC+01:00)
# vikunja-reminder-agent-1  |     ReminderUtc          = 2/22/2026 5:25:00 PM
# vikunja-reminder-agent-1  |     TaskId               = 1
# vikunja-reminder-agent-1  |     TaskTitle            = ExampleTask
# vikunja-reminder-agent-1  |     TaskUrl              = http://localhost:3456/tasks/1
# vikunja-reminder-agent-1  |     Timezone             = (UTC+01:00) Central European Time (Warsaw)
# vikunja-reminder-agent-1  |
# vikunja-reminder-agent-1  | [18:17:47] Polling | window 18:17:42 -> 18:27:52 Europe/Warsaw
# vikunja-reminder-agent-1  |   Filter         : done = false && reminders >= now-5s && reminders <= now+605s
# vikunja-reminder-agent-1  |   Skipped (already fired): task #1 @ 2026-02-22 18:25:00 Europe/Warsaw