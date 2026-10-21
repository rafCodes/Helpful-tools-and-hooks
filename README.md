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

**Hooks** (`hooks.json` → `hooks/`): agentStop (text-to-speech + sound) and notification (permission toasts and persistent question alerts). Alerts use fixed text. Alerts do not copy question or command content into Windows notification history. Helpers: `FocusToast.Common.ps1`, `QuestionAlert.Common.ps1`, `HookLog.Common.ps1`, and `Show-Toast.ps1`.

### Question alerts

When the terminal does not have focus, a question opens a topmost alert on the monitor that contains the active app. The alert stays visible until you select **Dismiss** or close the alert with a mouse or touch. The alert does not take keyboard focus or switch apps. Keyboard dismissal is not available. The hook returns immediately.

Only one question alert stays open for each Windows user and administrator state in the current Windows session. Standard sessions and administrator sessions use separate alerts because Windows restricts shared access between those security contexts. A new question reuses its context's alert, moves the alert to the active app's monitor, and restarts the tone without overlapping playback. Rapid requests can share one replay. If a question arrives as you dismiss the alert, the alert stays open for the new question.

The alert does not use Windows toast delivery. Windows Do Not Disturb and full-screen toast suppression do not control the alert. The alert restores its topmost position once per second. This supports desktop apps and borderless full-screen apps. Windows cannot guarantee that a desktop overlay will appear above an exclusive-full-screen app, a secure desktop, or the lock screen.

The question sound uses the soft Windows `Windows Background.wav` notification tone, about 1.3 seconds long, at 75% player volume. The tone plays once and restarts for a new question. The hook does not change system volume, mute settings, or the volume of other apps. The output device and system volume still control the audible level. If sound playback fails, the alert stays visible and the hook logs `sound_play_failed`. The hook does not select a replacement sound. The reply-finished chime is unchanged.

Permission prompts still use standard Windows toasts. Alerts remain suppressed when the terminal already has focus.

The notification handler reads `notification_type` from stdin. The internal `hook.start` session event uses `notificationType`; that field is not the notification script's input format.

The hooks write best-effort results to `hooks.log` in `COPILOT_PLUGIN_DATA`. Each JSON line contains only a UTC timestamp, a fixed hook name, `worked` or `did_not_work`, and a fixed result code. The log does not store notification text, paths, session identifiers, tool arguments, or exception messages. The logger serializes concurrent writes and resets the file when it reaches 1 MiB. It drops an entry if the plugin data path is unavailable or the log lock is unavailable for two seconds.

> The agentStop **sound** (`Hook-AgentStopSound.ps1`) plays only when the main agent finishes. The hook compares `sessionId` with the session directory that contains `transcriptPath`. It suppresses sub-agent stops.

**TTS engine** lives in `hooks/text-to-speech/` (`speak.py` + `enabled.txt`, stdlib only) — used by the agentStop hook and toggled by the `toggle-text-to-speech` skill. Not exposed as a skill itself.

## Install / test locally

Run these commands yourself from the workspace directory.

```powershell
copilot plugin install ".\Helpful tools and hooks"
copilot plugin list
```

After source changes, run the install command again. Start a new Copilot CLI session after the refresh. Existing sessions can retain cached plugin configuration.

To remove the plugin, run `copilot plugin uninstall helpful-tools-and-hooks` yourself.

Run the local regression checks from the repository root in PowerShell 7. Use an unlocked interactive Windows desktop with a working audio device and Windows media playback support. Windows PowerShell 5.1 must permit the local test scripts to run.

```powershell
.\tests\Test-Hooks.ps1
```

A successful test prints `PASS hook regression checks`.

The notification tests pipe synthetic JSON through the actual handler. Test stubs replace focus detection and process launch. Renderer checks use a transparent borderless variant of the alert and muted playback. The checks verify native visibility after hidden startup, topmost recovery above a borderless full-screen window, initial focus preservation, the native mouse-activation response, the Dismiss action, the selected tone, and 75% player volume. Three concurrent request processes must signal the existing alert without creating another window or player. The checks also cover security-scope isolation, a question that arrives during dismissal, and an alert that remains visible after sound initialization fails.

The tests do not send real mouse clicks. The following manual procedure verifies the captioned production alert, real-click focus preservation, physical dismissal, and audible playback. The other regression checks cover questions, permission prompts, focused-terminal suppression, rejected input, launch failures, exact process arguments, empty stderr, and log privacy.

After each plugin update:

1. Open a borderless full-screen app.
2. Trigger a Copilot question from a terminal that does not have focus.
3. Confirm that one generic question alert appears above the app.
4. Confirm that the short Windows notification tone plays and that the full-screen app keeps keyboard focus.
5. Trigger another question.
6. Confirm that the same alert remains open and the tone restarts.
7. Click the alert body.
8. Confirm that the full-screen app keeps keyboard focus.
9. Select **Dismiss**.
10. Confirm that the alert closes and the full-screen app keeps keyboard focus.

The expected result is one closed alert with no change to system volume. If the alert or sound fails, check `hooks.log` in `COPILOT_PLUGIN_DATA` for `question_alert_display_failed` or `sound_play_failed`. A display failure after `question_alert_displayed` means that the alert could not maintain its topmost position. A lone `question_alert_dispatched` without a renderer result can mean that the child failed before rendering. Existing alerts use `question_alert_reused` and `question_alert_replayed` instead of a second `question_alert_displayed`.
