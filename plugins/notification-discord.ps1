# notification-discord.ps1
#
# Discord webhook plugin for Vikunja Reminder Agent.
#
# Provider options (set per-instance in rules.json):
#   webhook_url  (required) - Discord incoming webhook URL

Register-Plugin -Name "discord" -ScriptBlock {
    param(
        [hashtable] $Payload,
        [hashtable] $Options
    )

    $webhookUrl = $Options["webhook_url"]
    if (-not $webhookUrl) {
        Write-Warning "  [discord] Missing 'webhook_url' in provider options."
        return $false
    }

    $body = @{
        embeds = @(
            @{
                title       = "⏰ Reminder: $($Payload.TaskTitle)"
                url         = $Payload.TaskUrl
                description = $(if ($Payload.Description) { $Payload.Description } else { "*No description*" })
                color       = 0x7C3AED
                fields      = @(
                    @{ name = "📅 Reminder time"; value = $Payload.ReminderStr; inline = $true }
                    @{ name = "⚠ Priority"; value = "$($Payload.Priority)"; inline = $true }
                    @{ name = "✅ Done"; value = $task.done.ToString(); inline = $true }
                    @{ name = "🗂️ Project"; value = "ID $($Payload.ProjectId)"; inline = $true }
                )
                footer      = @{ text = "Vikunja • Task #$($Payload.TaskId)" }
                timestamp   = $Payload.ReminderUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        )
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $body -ContentType "application/json" | Out-Null
        Write-Host "  [discord] Sent: task #$($Payload.TaskId) '$($Payload.TaskTitle)'"
        return $true
    }
    catch {
        Write-Warning "  [discord] Failed: $_"
        return $false
    }
}
