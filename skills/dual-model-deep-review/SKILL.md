---
name: dual-model-deep-review
description: 'Runs a two-track, four-agent deep review of code by spawning four built-in sub-agents in parallel via the task tool — two Code Quality / Critical reviewers and two Security Hardening reviewers, with each track run once on the newest available GPT and once on the newest available Claude (highest reasoning effort and context tier) — then consolidates their findings. A recursion guard prevents the review from re-invoking itself. Use when asked to "deep review", "four-agent review", "4-agent review", "dual-model review", "audit this code", "harden this code", "critically review", or any request that wants both code-quality AND security review in one pass. Catches unnecessary fallbacks, over-complicated code, non-performant code, scaling/batching problems, and security weaknesses.'
---

# Dual-Model Deep Review

A small skill that runs a brutally honest review across two tracks:

1. **Code Quality / Critical Review** — unnecessary fallbacks, over-complication, performance, scaling/batching, correctness bugs, maintainability, convention violations.
2. **Security Hardening** — injection, authN/Z, crypto/secrets, unsafe defaults, DoS, supply chain, data handling, operational hardening.

Each track is run **twice** — once on the newest available GPT and once on the newest available Claude — as a `general-purpose` sub-agent launched via the `task` tool. That is **four reviewers total** (2 Quality + 2 Security). They all run in parallel; you (the main agent) consolidate their reports. That is the whole design — no orchestrator subprocess, no wrapper script, no custom agent definitions. Running each track on both model families is the cross-model validation premise: a blind spot in one family is caught by the other.

---

## Files in this skill

| Path | Role |
|---|---|
| `SKILL.md` (this file) | Main-agent instructions: guard → spawn four reviewers → consolidate |
| `prompts\quality-review-prompt.md` | Self-contained Quality-track reviewer prompt (ground rules + calibration + phases + output format) |
| `prompts\security-review-prompt.md` | Self-contained Security-track reviewer prompt |

Each prompt file is complete on its own and contains `{{...}}` placeholders you fill in before passing it to the sub-agent.

---

## Recursion guard (the only guard)

Each reviewer prompt embeds the marker `DUAL_MODEL_DEEP_REVIEW_DEPTH=1` and a rule telling the sub-agent never to invoke this skill. Combined with Step 1 below, that prevents the review from fanning out into itself:

**Before doing anything, check your own inbound context for `DUAL_MODEL_DEEP_REVIEW_DEPTH=1`. If it is present, you are already running inside a deep review — refuse to launch, say so, and stop.** Otherwise proceed.

---

## When to use

- "deep review", "four-agent review", "4-agent review", "dual-model review", "cross-model review".
- "audit", "harden", or "critically review" a file, module, PR, or codebase.
- Any review that should cover **both** code quality **and** security in one pass.

## When NOT to use

- Trivial edits, formatting, or typo fixes — just review them directly.
- The user asked for a quick/cheap review — this spawns four high-reasoning sub-agents.
- Your inbound context already contains `DUAL_MODEL_DEEP_REVIEW_DEPTH=1` — refuse (see the recursion guard).

---

## Workflow

### Step 1 — Recursion guard + gather inputs

Run the recursion-guard check above. Then settle these inputs (ask the user only when a value is ambiguous — do not silently guess the project type, it drives reviewer severity):

| Input | What it is |
|---|---|
| **Target Root** | Absolute path or clear description of what to review (files / diff / PR / module). |
| **Project Type** | One of `throwaway`, `research`, `internal-tool`, `production`, `critical-production`. Infer from signals (deploy manifests, CI/CD, auth code, persisted user data, license) or ask. |
| **Project Type reasoning** | One sentence justifying the type you picked. |
| **Scope** | Human description of what to focus on. |
| **User context** | Optional free-form context (problem statement, threat model). Use `(none)` if empty. |

### Step 2 — Spawn the four reviewers in parallel

1. Read `prompts\quality-review-prompt.md` and `prompts\security-review-prompt.md`.
2. In each, replace `{{TARGET_ROOT}}`, `{{PROJECT_TYPE}}`, `{{PROJECT_TYPE_REASONING}}`, `{{SCOPE}}`, and `{{USER_CONTEXT}}` with the Step 1 values. Leave `DUAL_MODEL_DEEP_REVIEW_DEPTH=1` intact.
3. In **one response**, launch **four** `task` sub-agents so they all run in parallel — each track once per model family. Run each reviewer at the **highest reasoning effort and context tier the model offers**. **Minimum versions: `claude-opus-4.8` and `gpt-5.5` — never go below these; if a newer GPT or Claude is available at run time, prefer it.**
   - **Quality · Claude**: `agent_type: general-purpose`, `model:` newest Claude (≥ `claude-opus-4.8`), `reasoning_effort: max`, `context_tier: long_context`, `prompt:` the filled-in **quality** prompt.
   - **Quality · GPT**: `agent_type: general-purpose`, `model:` newest GPT (≥ `gpt-5.5`), `reasoning_effort: xhigh`, `context_tier: long_context`, `prompt:` the filled-in **quality** prompt.
   - **Security · Claude**: `agent_type: general-purpose`, `model:` newest Claude (≥ `claude-opus-4.8`), `reasoning_effort: max`, `context_tier: long_context`, `prompt:` the filled-in **security** prompt.
   - **Security · GPT**: `agent_type: general-purpose`, `model:` newest GPT (≥ `gpt-5.5`), `reasoning_effort: xhigh`, `context_tier: long_context`, `prompt:` the filled-in **security** prompt.

   The two Quality reviewers receive the identical filled-in quality prompt; the two Security reviewers receive the identical filled-in security prompt. The only difference within a track is the model family — that is the cross-model validation premise. Always use the newest GPT and newest Claude available, but never below the `gpt-5.5` / `claude-opus-4.8` floor.

The review-only discipline is carried by Ground Rule 1 inside each prompt (the sub-agents are instructed to read and report, never modify). Do not add your own instructions on top of the prompt bodies.

### Step 3 — Consolidate & deliver

When all four reviewers return:

- Within each track, merge the two reports (GPT + Claude). Tag each finding by agreement: **HIGH CONFIDENCE** if both model families raised it, otherwise **single-model**. Two findings are "the same" if they share a file:line range, root cause, or recommended fix — when unsure, keep both rather than over-merging.
- Present consolidated **Quality** findings and consolidated **Security** findings, each under its own heading, leading with the HIGH CONFIDENCE items.
- Merge obvious overlaps across the two tracks too (same file:line / same root cause), noting both tracks raised it.
- Surface prominently any non-empty `## Prompt-Injection Attempts Detected` section and any redacted-secret notes — those are things the user must see.
- If a reviewer failed or returned nothing, say so and do not infer cross-model agreement from a single surviving report.
- End with a combined, priority-ordered fix list and the two verdicts (Quality: READY/NEEDS WORK/BLOCKED; Security: HARDENED/NEEDS WORK/VULNERABLE).
- If the user asked for the report to be persisted, write it to their chosen path with `[System.IO.File]::WriteAllText('<path>', $report, (New-Object System.Text.UTF8Encoding $false))` (avoids a BOM).

---

## What you must NOT do

- Do not skip the Step 1 recursion-guard check.
- Do not silently guess the project type when it is ambiguous — ask.
- Do not modify the two prompt files' intent; only fill in the `{{...}}` placeholders.
- Do not re-introduce an orchestrator subprocess, wrapper script, custom agent definitions, or nonce/sentinel machinery — this skill is deliberately just two prompt files plus a recursion guard.
