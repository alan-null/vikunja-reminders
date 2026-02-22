# notification-slack.ps1
#
# Slack bot token plugin for Vikunja Reminder Agent.
# Uses the official Slack Web API (chat.postMessage).
#
# Required scopes on your Slack app: chat:write, chat:write.customize
# If posting to public channels without joining: chat:write.public
#
# Provider options (set per-instance in rules.json):
#   token    (required) - Slack bot token, begins with xoxb-
#   channel  (required) - Channel ID (e.g. 'random') or user ID for a DM.

Register-Plugin -Name "slack" -ScriptBlock {
    param(
        [hashtable] $Payload,
        [hashtable] $Options
    )

    $token = $Options["token"]
    $channel = $Options["channel"]

    if (-not $token) {
        Write-Warning "  [slack] Missing 'token' in provider options."
        return $false
    }
    if (-not $channel) {
        Write-Warning "  [slack] Missing 'channel' in provider options."
        return $false
    }

    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type"  = "application/json; charset=utf-8"
    }

    $description = if ($Payload.Description) { $Payload.Description } else { "_No description_" }

    $blocks = @(
        @{
            type = "header"
            text = @{ type = "plain_text"; text = "Reminder: $($Payload.TaskTitle)"; emoji = $true }
        }
        @{
            type   = "section"
            fields = @(
                @{ type = "mrkdwn"; text = "*Reminder time*`n$($Payload.ReminderStr)" }
                @{ type = "mrkdwn"; text = "*Priority*`n$($Payload.Priority)" }
                @{ type = "mrkdwn"; text = "*Project*`nID $($Payload.ProjectId)" }
                @{ type = "mrkdwn"; text = "*Done*`n$($Payload.Done)" }
            )
        }
        @{
            type      = "section"
            text      = @{ type = "mrkdwn"; text = $description }
            accessory = @{
                type = "button"
                text = @{ type = "plain_text"; text = "Open task"; emoji = $true }
                url  = $Payload.TaskUrl
            }
        }
        @{
            type     = "context"
            elements = @(
                @{ type = "mrkdwn"; text = "Vikunja Reminder Agent • Task #$($Payload.TaskId)" }
            )
        }
    )

    $body = @{
        channel  = $channel
        text     = "Reminder: $($Payload.TaskTitle) — $($Payload.ReminderStr)"
        blocks   = $blocks
        username = "Vikunja Reminder"
        icon_url = "https://raw.githubusercontent.com/git-hosted/cdn/refs/heads/master/vikunja-logo.png"
    } | ConvertTo-Json -Depth 10

    try {
        $response = Invoke-RestMethod `
            -Uri "https://slack.com/api/chat.postMessage" `
            -Method Post `
            -Headers $headers `
            -Body $body

        # Slack always returns HTTP 200 — actual success/failure is in response.ok
        if ($response.ok -ne $true) {
            Write-Warning "  [slack] API error: $($response.error)"
            return $false
        }

        Write-Host "  [slack] Sent: task #$($Payload.TaskId) '$($Payload.TaskTitle)' -> $channel"
        return $true
    }
    catch {
        Write-Warning "  [slack] Request failed: $_"
        return $false
    }
}