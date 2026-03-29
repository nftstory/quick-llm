# Quick Ask

Quick Ask is a compact macOS chat panel for short prompts.

It lives above your other windows, keeps the input bar pinned while the conversation grows upward, reuses existing CLI logins instead of API keys, and can save transcripts with encrypted-at-rest storage.

![Quick Ask screenshot](assets/quick-ask-sample.png)

## What It Does

- Toggle a floating panel with `Cmd+\`
- Open a separate history window with `Cmd+Shift+\`
- Start a fresh chat with `Cmd+N`
- Queue prompts while a reply is still streaming
- Steer to the next queued prompt with `Cmd+Enter`
- Cancel queued prompts without interrupting the current reply
- Restore earlier chats from encrypted saved history
- Gate first use with a small setup screen for history + provider detection
- Pick your own archive folder or disable history entirely
- Switch between ChatGPT via Codex CLI, Gemini via Gemini CLI, and installed Ollama models
- Recheck Claude, Codex, Gemini, and local-model availability from `Settings…`

## Requirements

- macOS
- Python 3
- Xcode command line tools
- Any of: Claude CLI, Codex CLI, Gemini CLI, Ollama
- `openssl` and macOS Keychain access for transcript encryption

## Storage

Transcript saves are encrypted before they are written to disk.

- On first setup, Quick Ask asks whether history should be enabled.
- If history is enabled, Quick Ask requires you to pick the archive folder yourself.
- If history is disabled, Quick Ask does not save transcripts.
- The encryption key is stored in macOS Keychain under the service name `local-chat-transcript-key`.
- The app writes encrypted transcript files only. It does not write plaintext chat logs during normal use.
- You can still override the transcript folder with `QUICK_ASK_SAVE_DIR` or disable history with `QUICK_ASK_DISABLE_HISTORY=1`.

## Build

From the project directory:

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
2. On first use, choose whether history is enabled and, if so, where encrypted archives should live.
3. If you want remote providers, make sure you have already logged in through the relevant CLI:
   - `claude auth login --claudeai`
   - `codex login --device-auth`
   - `gemini`
4. Press `Cmd+\` to show or hide the panel.
5. Type a prompt and press `Enter`.
6. Use the model menu to switch providers or open `Settings…`.
7. Press `Cmd+Shift+\` to browse and restore prior chats when history is enabled.

## Development

Run the UI suite with:

```zsh
python3 tests/test_quick_ask_ui.py -v
```

The UI tests do not send real chat prompts to Claude, Codex, Gemini, or Ollama. They run the app in a test mode with stubbed generation so layout, queueing, setup gating, history, and shortcut behavior can be verified without burning inference tokens.
