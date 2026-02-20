# Careless Whisper

A macOS menu bar app for **push-to-talk voice-to-text transcription** using OpenAI's Whisper model — all processed locally on your machine with no cloud API calls.

## How It Works

1. **Hold a hotkey** (default: `Option+`\`) → the mic starts recording and a floating HUD overlay appears showing a timer and live transcription
2. **Speak** → Voice Activity Detection (VAD) splits speech into chunks, each transcribed in real-time via [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
3. **Release the hotkey** → the final transcription is assembled and automatically typed into the frontmost app

## Features

- **Local transcription** via [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) (whisper.cpp) — no API keys or internet required at runtime
- **Three English model sizes**: Tiny (75 MB), Base (142 MB), Small (466 MB), downloaded from HuggingFace
- **Live transcription preview** in a floating non-activating overlay during recording
- **Customizable hotkey** with presets (Option+\`, F5, Ctrl+Shift+Space, F19)
- **Input device selection** with multiple microphone support via CoreAudio
- **Smart text injection**:
  - Kitty terminal → native IPC via `kitten @ send-text`
  - All other apps → clipboard + simulated Cmd+V (original clipboard restored afterwards)
- **Optional auto-Enter** after transcription
- **Completion sound** toggle
- **Recent transcription history** (last 20) accessible from the menu bar
- **Launch at login** support via `SMAppService`
- **Auto-stop** after 60 seconds of recording

## Requirements

- macOS 14 (Sonoma) or later
- **Microphone permission** — for audio capture
- **Accessibility permission** — for simulating keystrokes (Cmd+V paste)

## Building

```bash
# Debug build
swift build

# Release build
swift build -c release
```

### Creating an App Bundle

```bash
# Debug
./scripts/bundle.sh

# Release
./scripts/bundle.sh --release
```

The `.app` bundle is output to `./build/CarelessWhisper.app`. Copy it to `/Applications` to install:

```bash
cp -r build/CarelessWhisper.app /Applications/
```

## Architecture

```
CarelessWhisperApp (entry point)
├── AppState          — central @MainActor orchestrator (idle → recording → transcribing → idle)
├── StatusBarController — NSStatusBar menu with status, history, and actions
│
├── Audio/
│   ├── AudioCaptureService — AVAudioEngine tap, 16 kHz mono resampling, VAD chunking
│   └── AudioBuffer         — os_unfair_lock thread-safe accumulator for real-time audio thread
│
├── Transcription/
│   ├── WhisperService — SwiftWhisper wrapper (Task.detached to avoid MainActor deadlock)
│   └── ModelManager   — model download, storage, and caching (~/.../Application Support/)
│
├── TextInjection/
│   ├── TextInjectorCoordinator — strategy router (Kitty IPC → clipboard fallback)
│   ├── KittyIPC               — Kitty terminal socket discovery and remote control
│   └── ClipboardPaster        — clipboard + CGEvent keystroke simulation
│
├── HotKey/
│   └── HotKeyManager — global hotkey registration with UserDefaults persistence
│
├── Permissions/
│   └── PermissionChecker — microphone + accessibility permission handling
│
└── UI/
    ├── SettingsView/Window  — SwiftUI settings (hotkey, model, device, toggles)
    ├── RecordingOverlay     — floating NSPanel HUD with live transcription
    └── MenuBarView          — SwiftUI menu bar content
```

## Settings

Access settings from the menu bar icon. Available options:

| Setting | Description |
|---------|-------------|
| **Hotkey** | Push-to-talk key combo with preset options |
| **Whisper Model** | Tiny, Base, or Small (English-only) |
| **Input Device** | Select from available microphones |
| **Completion Sound** | Play a sound when transcription finishes |
| **Press Enter** | Automatically press Enter after injecting text |
| **Launch at Login** | Start the app automatically on login |

## Dependencies

- [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) — whisper.cpp Swift bindings
- [HotKey](https://github.com/soffes/HotKey) — global hotkey registration

## License

See [LICENSE](LICENSE) for details.
