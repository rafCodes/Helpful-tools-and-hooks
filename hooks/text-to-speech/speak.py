#!/usr/bin/env python3
"""Text-to-speech skill using Windows SAPI.

Speech rate scales with text length so short messages don't sound rushed
and long messages don't drag on. Override with --rate=N (-10..10).
"""

import os
import re
import sys
import subprocess

_ENABLED_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "enabled.txt")

def is_enabled() -> bool:
    """Read enabled.txt next to this script. Missing/unreadable file = enabled."""
    try:
        with open(_ENABLED_FILE, "r", encoding="utf-8-sig") as f:
            return f.read().strip().lower() not in ("false", "0", "off", "no")
    except OSError:
        return True

_FENCED_CODE = re.compile(r"```.*?```", re.DOTALL)
_INDENTED_CODE = re.compile(r"(?m)^(?: {4}|\t).*$")
_INLINE_CODE = re.compile(r"`([^`]+)`")
_TABLE_LINE = re.compile(r"(?m)^[ \t]*\|.*\|[ \t]*$")
_TABLE_SEP = re.compile(r"(?m)^[ \t]*\|?[ \t:\-|]+\|[ \t:\-|]*$")
_HEADER = re.compile(r"(?m)^[ \t]{0,3}#{1,6}[ \t]+")
_ORPHAN_HASHES = re.compile(r"(?<![\w/])#{1,6}(?=\s|$)")
_BLOCKQUOTE = re.compile(r"(?m)^[ \t]{0,3}>[ \t]?")
_HRULE = re.compile(r"(?m)^[ \t]{0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$")
_BULLET = re.compile(r"(?m)^[ \t]*[-*+][ \t]+")
_NUM_BULLET = re.compile(r"(?m)^[ \t]*\d+[.)][ \t]+")
_LINK = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
_BARE_URL = re.compile(r"https?://\S+")
_PATH_TOKEN = re.compile(r"\S*\\\S+|\S+\\\S*|[A-Za-z]:[\\/]\S*")
_PATH_DEDUP = re.compile(r"\bpath(?:\s+path)+\b")
_EMPHASIS_DOUBLE = re.compile(r"(\*\*|__)(.+?)\1")
_EMPHASIS_SINGLE = re.compile(r"(?<!\w)([*_])(?!\s)(.+?)(?<!\s)\1(?!\w)")
_STRIKE = re.compile(r"~~(.+?)~~")
_HTML_TAG = re.compile(r"<[^>]+>")
_EMOJI = re.compile(
    "[" "\U0001F300-\U0001FAFF" "\U00002600-\U000027BF" "\U0001F000-\U0001F2FF" "]",
    flags=re.UNICODE,
)
_MULTI_WS = re.compile(r"[ \t]+")
_MULTI_NL = re.compile(r"\n{2,}")
_ESSENTIALLY_EMPTY = re.compile(r"^[\s.,;:!?\-]*$")

def clean_for_speech(text: str) -> str:
    """Strip markdown noise that sounds jarring when read aloud."""
    t = text
    t = _FENCED_CODE.sub(" ", t)
    t = _TABLE_SEP.sub("", t)
    t = _TABLE_LINE.sub("", t)
    t = _INDENTED_CODE.sub("", t)
    t = _HRULE.sub("", t)
    t = _LINK.sub(r"\1", t)
    t = _BARE_URL.sub("link", t)
    t = _PATH_TOKEN.sub("path", t)
    t = _INLINE_CODE.sub(r"\1", t)
    t = _EMPHASIS_DOUBLE.sub(r"\2", t)
    t = _EMPHASIS_SINGLE.sub(r"\2", t)
    t = _STRIKE.sub(r"\1", t)
    t = _HEADER.sub("", t)
    t = _ORPHAN_HASHES.sub("", t)
    t = _BLOCKQUOTE.sub("", t)
    t = _BULLET.sub("", t)
    t = _NUM_BULLET.sub("", t)
    t = _HTML_TAG.sub("", t)
    t = _EMOJI.sub("", t)
    t = _MULTI_WS.sub(" ", t)
    t = _MULTI_NL.sub(". ", t)
    t = t.replace("\n", " ").strip()
    t = _PATH_DEDUP.sub("path", t)
    t = re.sub(r"\s+([.,;:!?])", r"\1", t)
    t = re.sub(r"\.{2,}", ".", t)
    t = t.strip()
    if _ESSENTIALLY_EMPTY.match(t):
        return ""
    return t

# Length -> SAPI rate (-10 slow ... +10 fast). Extended scale so 1000+ char
# messages don't drag, but cap at 8 to stay intelligible.
def rate_for_length(n: int) -> int:
    if n <= 40:    return 0
    if n <= 100:   return 1
    if n <= 200:   return 2
    if n <= 350:   return 3
    if n <= 550:   return 4
    if n <= 800:   return 5
    if n <= 1100:  return 6
    if n <= 1500:  return 7
    return 8

def speak(text: str, rate: int):
    """Use Windows built-in SAPI via PowerShell. Serialized across processes
    via a named Windows mutex so concurrent invocations queue rather than
    overlap on the audio device."""
    rate = max(-10, min(10, rate))
    escaped_text = text.replace('"', '`"').replace("'", "''")
    ps_command = (
        'Add-Type -AssemblyName System.Speech;'
        '$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer;'
        f'$synth.Rate = {rate};'
        f'$synth.Speak("{escaped_text}")'
    )

    mutex = None
    acquired = False
    try:
        import ctypes
        from ctypes import wintypes
        k32 = ctypes.windll.kernel32
        k32.CreateMutexW.restype = wintypes.HANDLE
        k32.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
        k32.WaitForSingleObject.restype = wintypes.DWORD
        k32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        k32.ReleaseMutex.argtypes = [wintypes.HANDLE]
        k32.CloseHandle.argtypes = [wintypes.HANDLE]
        # "Global\" prefix would share across sessions; plain name is per-session,
        # which is what we want (multiple Copilot sessions shouldn't block each other).
        mutex = k32.CreateMutexW(None, False, "CopilotSpeakTTS")
        if mutex:
            # WAIT_OBJECT_0 = 0, WAIT_ABANDONED = 0x80 (previous holder died — still safe to proceed)
            result = k32.WaitForSingleObject(mutex, 0xFFFFFFFF)
            acquired = result in (0, 0x80)
    except Exception:
        pass

    try:
        subprocess.run(["powershell", "-Command", ps_command], check=True)
    finally:
        if mutex:
            try:
                if acquired:
                    ctypes.windll.kernel32.ReleaseMutex(mutex)
                ctypes.windll.kernel32.CloseHandle(mutex)
            except Exception:
                pass

def _safe_print(msg: str):
    """Print, falling back to ASCII when stdout can't handle Unicode (cp1252 etc.)."""
    try:
        print(msg)
    except UnicodeEncodeError:
        enc = sys.stdout.encoding or "ascii"
        print(msg.encode(enc, errors="replace").decode(enc, errors="replace"))

def main():
    args = sys.argv[1:]
    if not args:
        _safe_print("Usage: python speak.py [--rate=N] [--raw] [--max-chars=N] [--file=PATH | <text>]")
        sys.exit(1)

    rate_override = None
    raw = False
    max_chars = 2000
    file_path = None
    text_args = []
    for a in args:
        if a.startswith("--rate="):
            try:
                rate_override = int(a.split("=", 1)[1])
            except ValueError:
                _safe_print(f"Invalid --rate value: {a}")
                sys.exit(1)
        elif a in ("--raw", "--no-clean"):
            raw = True
        elif a.startswith("--max-chars="):
            try:
                max_chars = int(a.split("=", 1)[1])
            except ValueError:
                _safe_print(f"Invalid --max-chars value: {a}")
                sys.exit(1)
        elif a.startswith("--file="):
            file_path = a.split("=", 1)[1]
        else:
            text_args.append(a)

    if file_path:
        try:
            with open(file_path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError as e:
            _safe_print(f"Cannot read --file {file_path}: {e}")
            sys.exit(1)
        finally:
            try:
                if os.path.basename(file_path).startswith("copilot-speak-"):
                    os.remove(file_path)
            except OSError:
                pass
    elif text_args:
        text = " ".join(text_args)
    else:
        _safe_print("Usage: python speak.py [--rate=N] [--raw] [--max-chars=N] [--file=PATH | <text>]")
        sys.exit(1)

    if not raw:
        text = clean_for_speech(text)
    if not text:
        _safe_print("(nothing to speak after cleanup)")
        return
    if not is_enabled():
        _safe_print(f"(TTS disabled via {_ENABLED_FILE})")
        return
    if max_chars > 0 and len(text) > max_chars:
        text = text[:max_chars].rstrip() + "..."
    rate = rate_override if rate_override is not None else rate_for_length(len(text))
    _safe_print(f"🔊 Speaking (rate={rate}): {text[:100]}{'...' if len(text) > 100 else ''}")
    speak(text, rate)
    _safe_print("✓ Done")

if __name__ == "__main__":
    main()
