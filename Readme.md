# Yap

A fast, local-first dictation app for macOS. Hold a hotkey, speak, release — your speech is transcribed locally with Whisper and pasted into whatever app you're using. Optional local LLM cleanup turns "um like grab lunch tomorrow" into "Grab lunch tomorrow." before it lands. Free alternative to WisprFlow.

Apple Silicon only. Menu-bar app, no Dock clutter.

## Features

- Hold-to-talk dictation triggered by any modifier key (Right ⌥ / Fn / etc.) or shortcut
- Local Whisper transcription (whisper.cpp) and FluidAudio Parakeet (English-only) engines
- 30+ languages including English, Hindi, Telugu, Tamil, Bengali, Marathi, Punjabi, Kannada, Malayalam, Gujarati, Urdu, Japanese, Mandarin, Spanish, French, German, Arabic, and more
- Smart paste: drops dictated text into the focused text field, or copies to the clipboard with a notification when there isn't one
- Auto-submit in chat apps (Claude, ChatGPT, Slack, Messages, Discord, Teams, Telegram, WhatsApp) — paste, then synthetic Return after a configurable delay, with focus-drift abort
- Custom vocabulary via Whisper's initial prompt (jargon, names, project terms)
- Optional AI cleanup pass via local Ollama: punctuation, capitalization, fillers stripped, with silent fallback to the raw transcript when Ollama isn't running
- Modern glass-morphism UI

## Install

Apple Silicon Mac (arm64) running macOS 14+.

```sh
git clone https://github.com/rahulsaimallam/yap.git
cd yap
git submodule update --init --recursive
brew install cmake libomp rust ruby
gem install xcpretty
./run.sh build
```

The build script signs with a local self-signed certificate and a designated requirement so TCC permissions persist across rebuilds.

For AI cleanup:

```sh
brew install ollama && brew services start ollama
ollama pull llama3.2:3b
```

Then turn on the toggle in Yap → Settings → Cleanup.

## Hotkey

Default trigger is the right Option key. Configure in Settings → Shortcuts: pick a single modifier (Right ⌥, Left ⌥, Fn, etc.) or a key combination, plus hold-to-record vs tap-to-toggle.

## Privacy

Audio never leaves your machine.

- Whisper / Parakeet run locally
- Ollama (if enabled) runs on `localhost:11434`
- No telemetry, no network calls outside the configurable Ollama endpoint and one-time model downloads from Hugging Face

## Acknowledgements

Yap is a heavily reworked fork of [OpenSuperWhisper by Starmel](https://github.com/Starmel/OpenSuperWhisper), itself built on:

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) by Georgi Gerganov
- [FluidAudio](https://github.com/AntinomyCollective/FluidAudio) Parakeet
- [autocorrect](https://github.com/huacnlee/autocorrect) for Asian language postprocessing
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus

Original OpenSuperWhisper is MIT-licensed, and so is Yap. See [LICENSE](LICENSE).

## License

MIT. See [LICENSE](LICENSE).
