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

**Hooks** (`hooks.json` → `hooks/`): agentStop (text-to-speech + sound), notification (permission toasts and persistent question alerts), sessionStart (local configuration), and preCompact (opt-in compaction alerts). Question and permission alerts use fixed text. Alerts do not copy question or command content into Windows notification history. Helpers: `FocusToast.Common.ps1`, `QuestionAlert.Common.ps1`, `Compaction.Common.ps1`, `HookLog.Common.ps1`, and `Show-Toast.ps1`.

### Compaction alerts

Compaction reduces the conversation context that the model receives. The `preCompact` hook runs before each manual or automatic compaction attempt. The supplied hook reference does not define a completion hook. The alert therefore says **Copilot is compacting**, not **Compacted**. Repeated alerts identify repeated attempts. An alert does not confirm success or stop a compaction loop.

The `sessionStart` hook creates `%USERPROFILE%\.copilot\helpful-tools-and-hooks.json` when the file does not exist. The `preCompact` hook only reads the file. If `COPILOT_HOME` is set, both hooks use that directory instead. `COPILOT_HOME` must be an absolute local drive path. Network and device paths are not supported. The generated default is:

```json
{
  "compactionToastEnabled": false
}
```

The hooks preserve an existing configuration file. The plugin does not enable alerts for other users.

To enable compaction alerts:

1. Install or refresh the plugin.
2. Start a new Copilot CLI session.
3. Open `%USERPROFILE%\.copilot\helpful-tools-and-hooks.json`. Use the `COPILOT_HOME` directory if that variable is set.
4. Set `compactionToastEnabled` to the JSON boolean `true`.
5. Save the file.

The next compaction attempt shows a persistent alert with the session name and full session ID. No restart is required for changes to this setting. Set the value to `false` to disable new compaction alerts. Dismiss an existing alert separately.

The alert uses the question alert's style, sound, Dismiss button, and non-activating behavior. It appears even when the terminal has focus. Each session uses a separate, fixed-size compaction card. Alerts stack upward from the bottom-right of the active monitor. An additional column opens to the left when the current column is full. The layout reserves the top-right area for question alerts. It admits a new card before other cards can include that card in a reflow. Another attempt in the same session reuses that alert, refreshes the session name, and restarts the tone. Compaction alerts do not replace question alerts.

An existing card stays on its current monitor when another compaction occurs. If the layout cannot fit or a peer's placement fails, the renderer logs `compaction_alert_layout_failed` once when the card enters that failure state. The renderer keeps the card open and clamps it into the current monitor's work area when possible. The tone still replays. Cards can overlap if the display area becomes too small. A failed clamp logs `compaction_alert_clamp_failed` once per clamp-failure episode. A successful layout or clamp clears the corresponding failure state. The renderer writes these entries after releasing the layout mutex. Neither layout error closes an existing card.

Standard and administrator sessions use separate stacks. Each stack belongs to one Windows user and Windows session. Windows restricts access between these security contexts.

The hook payload provides `sessionId` and `transcriptPath`. It does not provide a session name. The renderer reads the name from `session-state\<sessionId>\workspace.yaml` below the Copilot configuration directory. It accepts an inline plain, single-quoted, or JSON-compatible double-quoted `name` value of 1 to 512 characters. It rejects multiline names, YAML null values, control characters, line separators, and bidirectional formatting controls. The renderer passes the name to a text control, not to PowerShell code or XAML. Long names use a scrollable area. The full ID and Dismiss button remain outside that area.

If the configuration is missing, invalid, or unreadable, the hook logs `configuration_failed` and does not show an alert. If the session name cannot be read, the alert shows **Session name unavailable** and the full ID. The renderer logs `session_name_unavailable`. The alert stays open. A later attempt can restore the name. A display failure logs `compaction_alert_display_failed`. This includes a monitor work area that cannot fit another alert. The new card is rejected without closing existing cards. Dismiss an existing alert to free space. A launch failure logs `compaction_alert_dispatch_failed`. These failures do not block compaction. The hook log does not store names, session IDs, or custom compaction instructions.

Compaction alerts show session names and IDs on the desktop. These values can appear in screen sharing and recordings. Windows Do Not Disturb does not suppress these alerts. Enable this setting only when that visibility is acceptable.

Hook API sources:

- https://docs.github.com/en/copilot/reference/hooks-reference
- https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks

### Question alerts

When the terminal does not have focus, a question opens a topmost alert on the monitor that contains the active app. The alert stays visible until you select **Dismiss** or close the alert with a mouse or touch. The alert does not take keyboard focus or switch apps. Keyboard dismissal is not available. The hook returns immediately.

Only one question alert stays open for each Windows user and administrator state in the current Windows session. Standard sessions and administrator sessions use separate alerts because Windows restricts shared access between those security contexts. A new question reuses its context's alert, moves the alert to the active app's monitor, and restarts the tone without overlapping playback. Rapid requests can share one replay. If a question arrives as you dismiss the alert, the alert stays open for the new question.

The alert does not use Windows toast delivery. Windows Do Not Disturb and full-screen toast suppression do not control the alert. The alert restores its topmost position once per second. This supports desktop apps and borderless full-screen apps. Windows cannot guarantee that a desktop overlay will appear above an exclusive-full-screen app, a secure desktop, or the lock screen.

The question sound uses the soft Windows `Windows Background.wav` notification tone, about 1.3 seconds long, at 75% player volume. The tone plays once and restarts for a new question. The hook does not change system volume, mute settings, or the volume of other apps. The output device and system volume still control the audible level. If sound playback fails, the alert stays visible and the hook logs `sound_play_failed`. The hook does not select a replacement sound. The reply-finished chime is unchanged.

Permission prompts still use standard Windows toasts. Question and permission alerts remain suppressed when the terminal already has focus. Compaction alerts are not suppressed by terminal focus.

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

The compaction checks use isolated `COPILOT_HOME` directories. They verify default-disabled configuration on disk, preservation of user settings, read-only compaction configuration, manual and automatic triggers, rejected configuration and input, literal session names, session-specific dispatch, repeated-alert reuse, name refresh, name-read failures and recovery, and log privacy. Name-parser checks run in Windows PowerShell 5.1, the production renderer runtime. The renderer checks run for both question and compaction alerts. They also verify simultaneous question and compaction windows, separate renderer processes, non-overlapping bounds, visible ID and Dismiss controls, and independent dismissal.

The admission check runs an existing card's reflow before a new card acquires the layout mutex. The check rejects an oversized new card. Existing cards must remain visible and non-overlapping.

The admitted-card check forces a peer to exceed the monitor width during a repeat. The existing card must remain visible on the same monitor, return into view, log the layout failure, and replay the tone. Repeated failures must produce one layout-failure entry. Recovery followed by another failure must produce a second entry.

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

To check compaction alerts manually, enable `compactionToastEnabled` first:

1. Trigger a manual compaction in a new or restarted Copilot CLI session.
2. Confirm that the alert says **Copilot is compacting**.
3. Confirm that the alert shows that session's name and full ID.
4. Trigger another compaction in the same session.
5. Confirm that the existing alert remains open and the tone restarts.
6. Select **Dismiss**.

The expected result is one closed compaction alert with no change to keyboard focus. A disabled setting produces no new compaction alert. Compaction success or failure does not change the alert text.
