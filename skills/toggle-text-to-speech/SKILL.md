---
name: toggle-text-to-speech
description: Toggle the text-to-speech hook on or off. Use when asked to "mute Copilot", "stop the voice", "turn TTS on/off", "enable/disable speaking", or any request to silence/restore the spoken responses fired by the agentStop hook.
---

# Toggle Text-to-Speech

Flips the `enabled.txt` flag inside the `text-to-speech` skill so the
`Hook-AgentStop.ps1` TTS playback can be silenced without unloading hooks.

## Usage

Run the toggle script:

```powershell
powershell -File ./Toggle-Tts.ps1            # flip current state
powershell -File ./Toggle-Tts.ps1 -State on  # force on
powershell -File ./Toggle-Tts.ps1 -State off # force off
powershell -File ./Toggle-Tts.ps1 -Status    # just print state
```

Prints the new state (`enabled` or `disabled`). No CLI restart required —
`speak.py` re-reads the file on every invocation.

## Files

- `Toggle-Tts.ps1` — the toggle script.
- The flag file lives at `../text-to-speech/enabled.txt` (next to `speak.py`).
