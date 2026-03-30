# Quick Ask / quick-ask Specification

This document is the working product spec and execution checklist for `Quick Ask`.

It exists for two reasons:

1. Capture the intended behavior of the app in one place.
2. Keep a durable list of issues and required fixes so they are not lost during context compaction.

## Product Summary

`Quick Ask` is a compact, always-on-top macOS chat panel for short questions.

It should feel like a native instant-access utility:

- invoke with a global shortcut
- type immediately without extra clicks
- get answers inline in a slim floating panel
- optionally save encrypted transcript history
- reuse existing CLI-authenticated LLM access instead of API keys

The repository name is `quick-ask`.
The app name is `Quick Ask`.

## Primary User Goals

- Ask short questions quickly from anywhere on the Mac.
- Switch between local and cloud LLMs without leaving the panel.
- Reuse existing paid subscriptions / CLI auth where possible.
- Save chats safely, including to untrusted cloud folders, without exposing plaintext.
- Keep the UI minimal, fast, and predictable.

## Core Principles

- No API-key onboarding UI.
- Reuse existing CLI logins where possible.
- History is optional.
- If history is enabled, encryption must be ready before any chat is saved.
- The input bar should remain visually anchored while conversation grows upward.
- The app should never unexpectedly steal focus or duplicate itself.
- Errors should explain what happened in user terms.

## Supported Providers

### Cloud CLI providers

- Claude via Claude CLI login
- ChatGPT via Codex CLI login
- Gemini via Gemini CLI login

### Ollama providers

- Ollama models discovered from the local install

## Provider / Model Behavior

- The model picker shows only models that are currently enabled and currently available.
- If a provider disappears or becomes unavailable, its models should naturally disappear from the picker.
- The picker should not show stale or non-working entries.
- The app should support a manual refresh action to rescan available providers/models.

### Current intended defaults

- Show only the latest instant ChatGPT model in the default visible list.
- Additional available models should be configurable in Settings.
- Installed Ollama models should be discoverable and optionally shown.

### Conversation continuity across model switches

- Changing the selected model does not change the reply already in flight.
- The next submitted turn uses the newly selected model.
- The existing conversation history is passed to that new model unless the chat was reset with `/new` or equivalent fresh-chat behavior.

## Setup Behavior

- Setup should be minimal and optional.
- The user should not be blocked on provider setup if at least one usable model/provider is available.
- Provider setup in Settings is informational and reusable, not a hard onboarding wall.

### History gating

- If encrypted history is disabled, the app should be usable immediately.
- If encrypted history is enabled, the app must require a valid archive folder and a working encryption key before writing chats.

## History and Encryption

- History should save encrypted transcripts only.
- The encryption key should live in macOS Keychain.
- The UI should clearly explain that:
  - chats are encrypted before being written to disk
  - encrypted files can be stored in untrusted cloud storage
  - only someone with the key can decrypt them
  - the key must be available before history starts saving

### Archive folder behavior

- Default history path should be a subfolder named after the app.
- The chosen folder should be explicit and user-controllable.
- The Settings UI should make the current archive destination obvious.
- The app should not silently save chats to a location the user cannot later access.

## Windowing and Focus

### Main panel

- Toggle with global `Cmd+\\`
- Always on top
- Compact rectangular appearance
- Input field should be focused on invoke
- Input bar should remain anchored in place
- Conversation grows upward
- Maximum conversation-history height: 450 px

### History window

- Open with `Cmd+Shift+\\`
- Dismiss automatically when the main panel hides
- Restore prior chats from encrypted history
- Delete prior chats from encrypted history

### Settings window

- Open from the model menu and with `Cmd+,`
- Should open the actual app settings window, not an empty/incorrect one
- Should open centered on screen
- Should size itself to fit content, up to the full visible screen height
- Should scroll only after reaching that height cap

## Chat UX

- `Enter` sends
- If a reply is already in flight, newly submitted prompts should queue
- Queue should be visible above the input
- Each queued item should have:
  - its own `Steer` action
  - its own cancel/remove action
- Cancel UI should use an `x.circle`-style SF Symbol rather than text

### Fresh chat behavior

- `Cmd+N` starts a new chat
- First press on a non-fresh chat: create a fresh thread and clear visible history
- Second press on an already fresh chat: clear only the draft input

## Rendering

- Inline Markdown should render properly inside message bubbles
- Tables should render more cleanly than raw pipe syntax
- Links should be clickable in chat messages
- History/archived conversation restoration should preserve link usability as well

## Error Handling

- Errors should be model/provider specific when possible
- Raw infrastructure messages like `env: node: No such file or directory` should be translated into useful user-facing explanations
- The app should distinguish between:
  - model unavailable
  - provider not logged in
  - quota/rate-limit exhausted
  - missing local runtime dependency
  - backend startup failure

## Progress / Long-Running Behavior

- The app should make it obvious when a model is still working versus finished
- It should be clear whether the app is expected to follow up with a final answer
- Reasoning-heavy or tool-using models should not leave the user wondering whether the answer is still coming

## UI Design Requirements

- The panel should stay visually minimal
- It should still be obvious what is interactive and what is plain text
- Buttons/controls in Settings currently need stronger affordance than labels/body text

## Known Inconsistencies / Fixes Required

These are open issues that should be fixed, tested, and pushed.

- [x] Change the archive folder behavior/default so history saves to a subfolder with the same name as the app.
- [x] Make Settings visually clearer so buttons read as buttons and text reads as text.
- [x] Make Settings explain encrypted history clearly, including untrusted cloud storage safety and Keychain-based key storage.
- [x] Ensure the encryption key is ready before any encrypted history writes happen.
- [x] Disable the autofill/autocomplete dropdown that sometimes appears when the app is invoked.
- [x] Show only the latest instant ChatGPT model by default.
- [x] Add Settings controls to enable/disable available models/providers in the visible picker.
- [x] Keep manual refresh for providers/models and ensure unavailable models naturally disappear from the picker.
- [x] Fix `Cmd+,` so it opens the real settings window consistently.
- [x] Move queue actions to the per-item level.
- [x] Change queue cancel UI to an `x.circle`-style symbol.
- [x] Make hyperlinks clickable in the conversation view.
- [x] Make long-running/reasoning behavior clearer so users know whether an answer is still in progress.
- [x] Verify history restoration and follow-up behavior still make sense across provider/model switches.
- [x] Verify model switching semantics are explicit in the UI or documentation so users know the next turn uses the newly selected model with prior history.

## Verification Requirements

Before considering the open items complete:

- app builds successfully
- installed app is restarted from the rebuilt bundle
- UI suite passes
- changed behaviors are manually spot-checked when practical
- changes are committed and pushed to `main`

Latest verification snapshot:

- `./build-quick-ask`
- `python3 tests/test_quick_ask_ui.py -v`
- 21 passing UI tests
