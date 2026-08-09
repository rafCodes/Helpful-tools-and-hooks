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

**Hooks** (`hooks.json` → `hooks/`): agentStop (text-to-speech + sound), notification (permission focus toast), preToolUse (ask_user toast). Helpers: `FocusToast.Common.ps1`, `Show-Toast.ps1`.

> The agentStop **sound** (`Hook-AgentStopSound.ps1`) plays only when the main agent finishes. Sub-agent stops (from the task/explore tools) are filtered out: their `sessionId` is a tool-call id, not the session GUID, so the chime is suppressed.

**TTS engine** lives in `hooks/text-to-speech/` (`speak.py` + `enabled.txt`, stdlib only) — used by the agentStop hook and toggled by the `toggle-text-to-speech` skill. Not exposed as a skill itself.

## Install / test locally

```shell
copilot plugin install "./Helpful tools and hooks"
copilot plugin list
```

After changes, re-run `copilot plugin install` (cached between sessions). Uninstall: `copilot plugin uninstall helpful-tools-and-hooks`.
