# Helpful tools and hooks

A GitHub Copilot CLI **plugin** bundling a curated set of skills, agents, and hooks.

## Structure

```text
Helpful tools and hooks/
├── plugin.json     # Required manifest (name: helpful-tools-and-hooks)
├── skills/         # Skills (each in skills/NAME/SKILL.md)
├── agents/         # Custom agents (NAME.agent.md)
├── hooks/          # Scripts referenced by hooks.json
└── hooks.json      # Hook configuration
```

## Contents

**Skills** (in `skills/`):
- `dual-model-deep-review` — 4-agent (GPT+Claude) code-quality + security review
- `markitdown` — convert PDF/DOCX/XLSX/etc. to Markdown (venv recreated from `scripts/requirements.txt`)
- `toggle-text-to-speech` — mute/unmute the TTS hook

**Hooks** (`hooks.json` → `hooks/`): agentStop (text-to-speech + sound) and notification (permission and question focus toasts). Toasts use fixed text and do not copy question or command content into Windows notification history. Helpers: `FocusToast.Common.ps1`, `HookLog.Common.ps1`, and `Show-Toast.ps1`.

The notification handler reads `notification_type` from stdin. The internal `hook.start` session event uses `notificationType`; that field is not the notification script's input format.

The hooks write best-effort results to `hooks.log` in `COPILOT_PLUGIN_DATA`. Each JSON line contains only a UTC timestamp, a fixed hook name, `worked` or `did_not_work`, and a fixed result code. The log does not store notification text, paths, session identifiers, tool arguments, or exception messages. The logger serializes concurrent writes and resets the file when it reaches 1 MiB. It drops an entry if the plugin data path is unavailable or the log lock is unavailable for two seconds.

> The agentStop **sound** (`Hook-AgentStopSound.ps1`) plays only when the main agent finishes. The hook compares `sessionId` with the session directory that contains `transcriptPath`. It suppresses sub-agent stops.

**TTS engine** lives in `hooks/text-to-speech/` (`speak.py` + `enabled.txt`, stdlib only) — used by the agentStop hook and toggled by the `toggle-text-to-speech` skill. Not exposed as a skill itself.

## Install / test locally

```shell
copilot plugin install "./Helpful tools and hooks"
copilot plugin list
```

After changes, re-run `copilot plugin install` (cached between sessions). Uninstall: `copilot plugin uninstall helpful-tools-and-hooks`.

Run the local regression checks from the repository root in PowerShell 7:

```powershell
.\tests\Test-Hooks.ps1
```

A successful test prints `PASS hook regression checks`.

The notification tests pipe synthetic JSON through the actual handler. Test stubs replace focus detection and process launch, so the tests do not display toasts or play sounds. The tests cover questions, permission prompts, focused-terminal suppression, rejected input, exact process arguments, empty stderr, and log privacy. After each plugin update, trigger a question while another app has focus. Confirm that Windows displays one generic question toast and plays the notification sound.
