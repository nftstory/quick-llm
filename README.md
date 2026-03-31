# quick-ask

`quick-ask` is the repo for `Quick Ask`, a compact macOS chat panel for short prompts.

The app lives above your other windows, keeps the input bar pinned while the conversation grows upward, reuses existing CLI logins instead of API keys, and can save transcripts with encrypted-at-rest storage.

![Quick Ask screenshot](assets/quick-ask-sample.png)

## What It Does

- Toggle a floating panel with `Cmd+\`
- Open a separate history window with `Cmd+Shift+\`
- Open history from the model menu without leaving the panel
- Open a keyboard shortcuts reference from `Settings…`
- Start a fresh chat with `Cmd+N`
- Dismiss the focused Quick Ask window with `Cmd+W`
- Cycle visible models with `Cmd+[ / Cmd+]`
- Cycle model providers with `Ctrl+Tab / Ctrl+Shift+Tab`
- Queue prompts while a reply is still streaming
- Steer to the next queued prompt with `Cmd+Enter`
- Cancel queued prompts without interrupting the current reply
- Steer or remove each queued prompt individually
- Paste images from the clipboard into the composer
- Restore earlier chats from encrypted saved history
- Delete saved threads directly from the history window
- Show a small setup screen only when history is enabled but no archive folder has been chosen yet
- Pick your own archive folder or disable history entirely
- Switch between Claude via Claude CLI, ChatGPT instant or medium via Codex CLI, Gemini via Gemini CLI, and installed Ollama models
- Recheck Claude, Codex, Gemini, and Ollama availability from `Settings…`
- Hide or re-enable individual available models from `Settings…`

## Requirements

- macOS
- Python 3
- Xcode command line tools
- Any of: Claude CLI, Codex CLI, Gemini CLI, Ollama
- `openssl` and macOS Keychain access for transcript encryption

## Storage

Transcript saves are encrypted before they are written to disk.

- On first setup, Quick Ask asks whether history should be enabled.
- If history is enabled, Quick Ask saves into a `Quick Ask/sessions` subfolder inside the folder you choose.
- If history is disabled, Quick Ask does not save transcripts.
- The encryption key is stored in macOS Keychain under the service name `local-chat-transcript-key`.
- The app writes encrypted transcript files only. It does not write plaintext chat logs during normal use.
- You can still override the transcript folder with `QUICK_ASK_SAVE_DIR` or disable history with `QUICK_ASK_DISABLE_HISTORY=1`.

## Build

From the repo root:

```zsh
./build-quick-ask
```

That script:

- builds `Quick Ask.app`
- installs it into `~/Applications`
- bundles the Python backend and shared helper module
- installs a LaunchAgent so the app starts at login

## Usage

1. Launch Quick Ask.
2. If you want encrypted saved history, choose an archive folder in `Settings…`. If history is disabled, Quick Ask works without any archive setup.
3. If you want remote providers, make sure you have already logged in through the relevant CLI:
   - `claude auth login --claudeai`
   - `codex login --device-auth`
   - `gemini`
4. Press `Cmd+\` to show or hide the panel.
5. Type a prompt and press `Enter`.
   You can also paste images directly into the input with `Cmd+V`.
6. Use the model menu to switch providers or open `Settings…`.
   You can also open `History` directly from that menu.
7. Press `Cmd+Shift+\` to browse prior chats when history is enabled.
8. Press `Cmd+,` to toggle the real Quick Ask settings window.
9. Use the `Keyboard Shortcuts` button in settings for a compact shortcut reference.

If at least one provider or local model is already available, Quick Ask does not block you on provider setup. Provider status in `Settings…` is informational and reusable, not an API-key onboarding flow.

Image support notes:

- Pasted images are forwarded to Claude, ChatGPT/Codex, Gemini, and Ollama models.
- Quick Ask materializes pasted images as temporary local files for the CLI-backed providers that need file-path handoff.

Model switching semantics:

- changing the selected model does not interrupt the reply already in flight
- the next submitted turn uses the newly selected model
- the current conversation history carries forward until you start a fresh chat
- the conversation does not auto-clear while the panel is visible
- if the panel stays dismissed for 45 seconds, Quick Ask clears the conversation automatically

## Repo Notes

- Repo name: `quick-ask`
- GitHub: `nftstory/quick-ask`
- App name: `Quick Ask`
- License: Apache-2.0 with Commons Clause (source-available; resale requires permission)

## Development

Run the UI suite with:

```zsh
python3 tests/test_quick_ask_ui.py -v
```

The UI tests do not send real chat prompts to Claude, Codex, Gemini, or Ollama. They run the app in a test mode with stubbed generation so layout, queueing, setup gating, history, and shortcut behavior can be verified without burning inference tokens.

Additional smoke tests:

```zsh
python3 tests/test_backend_env.py -v
python3 tests/test_quick_ask_backend_images.py -v
python3 tests/test_fresh_install.py -v
```

If you want to verify a clean install path without loading the LaunchAgent, you can build with:

```zsh
QUICK_ASK_SKIP_LAUNCH_AGENT=1 ./build-quick-ask
```
