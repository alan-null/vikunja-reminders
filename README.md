# Vikunja Reminder Agent

This is a notification routing agent for [**Vikunja**](https://vikunja.io/) reminders.

It runs as a separate process (e.g. in Docker) and polls the Vikunja API for upcoming reminders at a configurable time window.

When a reminder is due, it evaluates it against a set of user-defined rules and dispatches it to one or more notification providers based on those rules.

## Overview

The agent has three distinct layers:


**Plugin** - knows HOW to send  (e.g. Discord, Slack, ntfy, …)

**Provider** - a named, configured instance of a **plugin** (e.g. "discord-personal" vs "discord-work")

**Rule** - conditions on the task → which providers to invoke


The **plugin** files live in `/plugins/`. The **provider instances and rules** are defined in a single JSON file at `/config/rules.json`, which is mounted as a Docker volume so you can edit it without rebuilding the image.

---

## Repository structure

```
/
├── Dockerfile                    ← Dockerfile for the agent
├── docker-compose.yml            ← example Docker Compose config for self-hosted setup
├── .env                          ← [CREATE] env variables file
├── .env.example                  ← example env file with descriptions
├── main.ps1                      ← main agent (do not edit)
├── plugins/                      ← notification plugins
├── state/
│   └── fired_reminders.json      ← internal file to track which reminders have been fired (do not edit)
├── ReminderEngine.psm1           ← core engine logic (do not edit)
├── ReminderEngine.Tests.ps1      ← Pester tests for the engine
│   ├── notification-discord.ps1
│   ├── notification-debug.ps1
│   └── notification-myapp.ps1    ← drop new plugins here
├── config/
│   ├── rules.json                ← [CREATE] your day-to-day config
│   └── rules.json.example        ← example config with comments and explanations
└── rules.schema.json             ← JSON Schema for validating rules.json (do not edit)
```

## Docker

The agent is distributed as a small PowerShell-based Docker image. Common workflows:

- Build the image locally:

  ```bash
  docker build -t vikunja-reminder-agent .
  ```

- Run with Docker Compose (recommended for local development):

  ```bash
  docker-compose up --build -d
  docker-compose logs -f vikunja-reminder-agent
  ```

- Run standalone with Docker (example):

  ```bash
  docker run --rm \
    -e VIKUNJA_API_URL="http://host.docker.internal:3456/api/v1" \
    -e VIKUNJA_API_TOKEN="tk_..." \
    -v "$(pwd)/config:/config" \
    -v "$(pwd)/plugins:/plugins" \
    -v "$(pwd)/state:/state" \
    vikunja-reminder-agent
  ```

Notes:

- Create your configuration file in `./config/rules.json` (see next section).
- Persisted state (fired reminders) is stored in `state/fired_reminders.json` via the `./state` volume — keep this mounted to avoid duplicate notifications.
- The provided `docker-compose.yml` maps `host.docker.internal` for accessing a locally running Vikunja instance; see `.env.example` for example values.

**Environment variables**

| Variable                 | Required | Default                                   | Description                                      |
| ------------------------ | -------- | ----------------------------------------- | ------------------------------------------------ |
| `VIKUNJA_API_TOKEN`      | ✅        | —                                         | API token from Vikunja → Settings → API Tokens   |
| `VIKUNJA_API_URL`        |          | `http://host.docker.internal:3456/api/v1` | Internal API URL (container-to-container).       |
| `VIKUNJA_PUBLIC_URL`     |          | API URL with `/api/v1` stripped           | Public URL used in notification links            |
| `CHECK_INTERVAL_SECONDS` |          | `60`                                      | How often to poll for reminders                  |
| `NOTIFY_BEFORE_SECONDS`  |          | `0`                                       | Fire notifications this many seconds early       |
| `PLUGINS_DIR`            |          | `/plugins`                                | Directory scanned for `notification-*.ps1` files |
| `CONFIG_FILE`            |          | `/config/rules.json`                      | Path to the rules configuration file             |



## Configuration - rules.json

The file has two top-level keys: `providers` and `rules`.

```json
{
  "providers": { ... },
  "rules":     [ ... ]
}
```

Each key is explained in detail below.

### Providers

A provider is a named instance of a plugin with its own configuration. You can define multiple instances of the same plugin — for example two different Discord webhooks.

```json
"providers": {
  "discord-personal": {
    "plugin": "discord",
    "options": {
      "webhook_url": "https://discord.com/api/webhooks/AAA/BBB"
    }
  },
  "discord-work": {
    "plugin": "discord",
    "options": {
      "webhook_url": "https://discord.com/api/webhooks/CCC/DDD"
    }
  },
  "slack-team": {
    "plugin": "slack",
    "options": {
      "webhook_url": "https://hooks.slack.com/services/XXX/YYY/ZZZ",
      "channel": "#reminders"
    }
  }
}
```

| Field     | Description                                                                                                                    |
| --------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `plugin`  | Must match the name passed to `Register-Plugin` in the plugin file (case-insensitive). You will find it in plugin script file. |
| `options` | Arbitrary key/value object passed as-is to the plugin. Each plugin documents its own options. (i.e. webhook URL )              |

### Rules

Rules are evaluated **in order, top to bottom** for every reminder that fires.

A rule matches when its conditions are satisfied. Matching rules have their providers invoked.

```json
"rules": [
  {
    "name": "High priority to Slack",
    "match": "all",
    "conditions": [
      { "field": "priority", "op": ">=", "value": 3 }
    ],
    "providers": ["slack-team"],
    "stop_on_match": false
  },
  {
    "name": "Catch-all",
    "match": "all",
    "conditions": [],
    "providers": ["discord-personal"],
    "stop_on_match": false
  }
]
```

| Field           | Required | Description                                                                          |
| --------------- | -------- | ------------------------------------------------------------------------------------ |
| `name`          | ✅        | Human-readable label, shown in logs when the rule fires                              |
| `match`         |          | `"all"` (AND, default) or `"any"` (OR) — how conditions are combined                 |
| `conditions`    | ✅        | Array of condition objects. Empty array `[]` matches every task (catch-all)          |
| `providers`     | ✅        | Array of provider instance names to invoke when this rule matches                    |
| `stop_on_match` |          | `false` (default) — keep evaluating later rules. `true` — stop after this rule fires |

### Condition fields

These are the task fields you can match against:

| Field             | Type     | Description                                                                                                               |
| ----------------- | -------- | ------------------------------------------------------------------------------------------------------------------------- |
| `project_id`      | integer  | Project the task belongs to                                                                                               |
| `priority`        | integer  | Priority level (0 = none, 1 = low … 4 = urgent, 5 = DO NOW)                                                               |
| `percent_done`    | integer  | Completion percentage (0–100)                                                                                             |
| `is_favorite`     | boolean  | Whether the task is starred                                                                                               |
| `has_attachments` | boolean  | Whether the task has any attachments                                                                                      |
| `done`            | boolean  | Whether the task is completed (normally always `false` since the agent filters done tasks, but included for completeness) |
| `title`           | string   | Task title                                                                                                                |
| `description`     | string   | Task description                                                                                                          |
| `labels`          | string[] | Label titles on the task — use `in`/`not_in` to match by name, e.g. `"value": ["urgent", "work"]`                         |
| `assignees`       | integer  | Number of assignees on the task                                                                                           |

### Operators

| Operator       | Applies to | Example                                                              |
| -------------- | ---------- | -------------------------------------------------------------------- |
| `=`            | any        | `{ "field": "project_id", "op": "=", "value": 1 }`                   |
| `!=`           | any        | `{ "field": "priority", "op": "!=", "value": 0 }`                    |
| `>`            | integer    | `{ "field": "priority", "op": ">", "value": 2 }`                     |
| `>=`           | integer    | `{ "field": "priority", "op": ">=", "value": 3 }`                    |
| `<`            | integer    | `{ "field": "percent_done", "op": "<", "value": 50 }`                |
| `<=`           | integer    | `{ "field": "assignees", "op": "<=", "value": 5 }`                   |
| `contains`     | string     | `{ "field": "title", "op": "contains", "value": "urgent" }`          |
| `not_contains` | string     | `{ "field": "description", "op": "not_contains", "value": "draft" }` |
| `in`           | any        | `{ "field": "project_id", "op": "in", "value": [1, 2, 5] }`          |
| `not_in`       | any        | `{ "field": "priority", "op": "not_in", "value": [0, 1] }`           |

> **Note on booleans:**
>
> Use JSON `true`/`false` (not strings): `{ "field": "is_favorite", "op": "=", "value": true }`

> **Note on `contains` / `not_contains`:**
>
>  The implementation uses PowerShell's `-like` operator internally, so `*` and `?` inside the value act as glob wildcards rather than literal characters. This is rarely a problem in practice but worth knowing if your task titles contain those characters.

### Rule evaluation

1. Rules are evaluated top-to-bottom for every reminder.
2. When a rule matches, its provider instances are added to the dispatch queue.
3. **De-duplication:** if two rules both reference `discord-personal`, it is only invoked once per reminder.
4. `stop_on_match: true` stops evaluation after the first matching rule —

   useful for a *firewall-style* priority chain where you want exactly one route per task.

7. A reminder is only written to the fired-state file if **at least one provider returns success**.

    If all providers fail, the reminder is retried on the next poll cycle.

8. If no rules match (or matched rules have no valid providers), a warning is logged and the reminder is not marked as fired.

### Full example

See example config here: [config/rules.json.example](config/rules.json.example)


---

## Writing a notification plugin

A plugin is a single `.ps1` file placed in the `/plugins/` directory. Its filename must start with `notification-` so the agent picks it up automatically on startup.


### Script structure

```powershell
Register-Plugin -Name "discord" -ScriptBlock {
    param(
        [hashtable] $Payload,
        [hashtable] $Options
    )
    # Your code here — use $Payload fields to build the request body, and $Options for config values
}
```

### The Payload object

Every plugin receives a `[hashtable]` called `$Payload` with the following keys:

| Key              | Type         | Description                                                        |
| ---------------- | ------------ | ------------------------------------------------------------------ |
| `TaskId`         | int          | Task ID                                                            |
| `TaskTitle`      | string       | Task title                                                         |
| `TaskUrl`        | string       | Full public URL to the task, ready to embed in messages            |
| `Description`    | string       | Task description (may be empty string)                             |
| `ProjectId`      | int          | Project ID                                                         |
| `Done`           | bool         | Completion status                                                  |
| `Priority`       | int          | Priority (0–5)                                                     |
| `PercentDone`    | int          | Completion percentage (0–100)                                      |
| `IsFavorite`     | bool         | Whether the task is starred                                        |
| `HasAttachments` | bool         | Whether the task has attachments                                   |
| `LabelCount`     | int          | Number of labels                                                   |
| `Labels`         | object[]     | Labels - copied from server response.                              |
| `AssigneeCount`  | int          | Number of assignees                                                |
| `ReminderUtc`    | datetime     | Reminder time in UTC — use for API/webhook timestamps              |
| `ReminderLocal`  | datetime     | Reminder time converted to the user's Vikunja timezone             |
| `ReminderStr`    | string       | Pre-formatted display string, e.g. `2026-02-22 22:21  (UTC+01:00)` |
| `Timezone`       | TimeZoneInfo | User's timezone object — use if you need custom date formatting    |

### The Options object

`$Options` is a `[hashtable]` built from the `"options"` block of the provider instance in `rules.json`. Your plugin defines what keys it expects — document them in a comment at the top of the file.

```powershell
# example
$webhookUrl = $Options["webhook_url"]   # required
$channel    = $Options["channel"]       # optional
```

### Example plugin skeleton

```powershell
# notification-myprovider.ps1
#
# Short description of what this plugin does.
#
# Provider options (configure per-instance in rules.json):
#   my_required_option  (required) - explanation
#   my_optional_option  (optional) - explanation, default: "something"

Register-Plugin -Name "myprovider" -ScriptBlock {
    param(
        [hashtable] $Payload,
        [hashtable] $Options
    )

    # 1. Validate required options
    $requiredOption = $Options["my_required_option"]
    if (-not $requiredOption) {
        Write-Warning "  [myprovider] Missing 'my_required_option' in provider options."
        return $false
    }

    # 2. Build the request body using $Payload fields
    $body = @{
        text = "Reminder: $($Payload.TaskTitle) at $($Payload.ReminderStr)"
        url  = $Payload.TaskUrl
    } | ConvertTo-Json

    # 3. Send the request
    try {
        Invoke-RestMethod -Uri $requiredOption -Method Post -Body $body -ContentType "application/json" | Out-Null
        Write-Host "  [myprovider] Sent: task #$($Payload.TaskId) '$($Payload.TaskTitle)'"
        return $true    # signal success — required
    }
    catch {
        Write-Warning "  [myprovider] Failed: $_"
        return $false   # signal failure — agent will retry next poll cycle
    }
}
```

**Key rules:**
- The name passed to `Register-Plugin` must be **lowercase** and match the `"plugin"` field in `rules.json`.
- The scriptblock **must return `$true`** on success and **`$false`** on failure. Throwing an exception is also treated as failure.
- Use `Write-Host` for normal output and `Write-Warning` for non-fatal errors.
- Do not use `Write-Error` or `exit` — those would crash the whole agent.
- Do not hardcode credentials. Read everything from `$Options` so each provider instance in `rules.json` can have its own values.


### Enabling and disabling plugins

| Action                    | How                                                                                           |
| ------------------------- | --------------------------------------------------------------------------------------------- |
| **Enable** a plugin       | Drop the `notification-*.ps1` file into `./reminder-agent/plugins/` and restart the container |
| **Disable** a plugin      | Remove or rename the file (e.g. `notification-slack.ps1.disabled`) and restart                |
| **Reload config**         | `rules.json` changes require only a container restart — no rebuild                            |
| **Add a new plugin type** | Write the `.ps1` file, add a provider entry and rules to `rules.json`, restart                |

The agent will log all loaded plugins and active providers on startup:

```text
[plugin] Loading notification-discord.ps1...
[plugin] Registered: discord
1 plugin(s) loaded: discord
Timezone       : Europe/Warsaw
```

## Development

### Tests

The repository includes a set of Pester tests for the core engine.

Run tests with:

```powershell
pwsh -Command "Invoke-Pester -Output Detailed"
```

Run integration tests for plugins with:

```powershell
# single plugin with custom options
.\Tests\test-plugins.ps1 -Plugin 'debug' -Options @{ Key1 = "https://discord.com/api/webhooks/AAA/BBB/CCC" }

# all plugins (make sure to set required options for each plugin in the command)
.\Tests\test-plugins.ps1 -Options @{ webhook_url = "https://discord.com/api/webhooks/X/Y/Z" }
```

## Resources

- [Vikunja API docs - filters](https://vikunja.io/docs/filters/#date-math)