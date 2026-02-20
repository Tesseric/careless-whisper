# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
swift build                    # debug build
swift build -c release         # release build
swift test                     # run all tests
swift test --filter CarelessWhisperTests.AudioBufferTests/testAppendAndFlush  # single test

./scripts/bundle.sh            # bundle as macOS .app (debug) → ./build/Careless Whisper.app
./scripts/bundle.sh --release  # bundle as macOS .app (release)
```

## Project Overview

Careless Whisper is a macOS menu bar app for push-to-talk voice-to-text. Hold a hotkey, speak, release — transcription appears at the cursor. Transcription is fully local via whisper.cpp (no API keys). When recording from a terminal, a floating HUD shows a live git/CI dashboard.

- **Swift 5.9+**, **macOS 14+**, built with **Swift Package Manager** (no Xcode project)
- Bundle ID: `com.carelesswhisper.app`
- Dependencies: [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) (whisper.cpp bindings), [HotKey](https://github.com/soffes/HotKey) (global hotkey via Carbon)
- Linked frameworks: AVFoundation, CoreAudio, Accelerate, Carbon

## Architecture

### Lifecycle

`CarelessWhisperApp.main()` → `NSApplication` with `.accessory` policy (no dock icon) → `AppDelegate` → creates `AppState` + `StatusBarController`.

### AppState — Central Orchestrator

`AppState` (`@MainActor`, `ObservableObject`) is the single source of truth. It owns all services and drives the state machine: `idle → recording → transcribing → idle`. It manages a chunk queue (`pendingChunks` + `processNextChunk()`) for serialized live transcription during recording.

### Module Responsibilities

- **Audio/** — `AudioCaptureService` captures mic via `AVAudioEngine`, resamples to 16kHz mono Float32, performs VAD (600ms silence → chunk boundary, min 300ms, max 10s). `AudioBuffer` is a thread-safe sample accumulator using `os_unfair_lock`.
- **Transcription/** — `WhisperService` wraps SwiftWhisper. Uses `Task.detached` to avoid `@MainActor` deadlock (SwiftWhisper resumes on `DispatchQueue.main`). `ModelManager` downloads GGML + optional CoreML models from HuggingFace to `~/Library/Application Support/CarelessWhisper/Models/`.
- **TextInjection/** — Strategy pattern via `TextInjectorCoordinator`. Priority: (1) Kitty IPC via `kitten @ send-text` over Unix socket, (2) Accessibility API (`AXUIElementSetAttributeValue`), (3) clipboard paste with Cmd+V simulation via `CGEvent`. Degrades gracefully through the chain.
- **Git/** — `GitContextService` detects terminal CWD via process tree + `lsof`, collects git status/diff/log, optionally queries `gh` CLI for CI/PR info. Displayed in the recording overlay HUD.
- **HotKey/** — `HotKeyManager` registers global hotkeys (default: Option+\`). Key down starts recording, key up stops and transcribes.
- **Permissions/** — Checks/requests microphone (`AVCaptureDevice`) and accessibility (`AXIsProcessTrusted`).
- **UI/** — `StatusBarController` (NSMenu-based menu bar), `RecordingOverlayController` (floating `NSPanel` HUD, non-activating), `SettingsWindowController`/`SettingsView` (SwiftUI settings).

## Conventions

- **Concurrency:** `@MainActor` on all UI/state classes. `async/await` throughout. `Task.detached` only in `WhisperService.transcribe()` to avoid deadlock. `AudioBuffer` uses `os_unfair_lock` for real-time audio thread safety.
- **Error handling:** Custom error enums with `LocalizedError` per module (`AudioCaptureError`, `WhisperServiceError`, `ModelManagerError`, `KittyIPCError`, `AXInjectionError`).
- **Logging:** `os.Logger` with subsystem `"com.carelesswhisper"` and per-module categories. Privacy markers on user-content fields.
- **Persistence:** `@AppStorage` (UserDefaults) for settings (selected model, input device, completion sound, auto-enter). Hotkey stored as raw key code + modifier flags.
- **UI pattern:** AppKit shell (`NSApplication`, `NSStatusItem`, `NSPanel`) with SwiftUI hosted in `NSHostingView` for settings and overlay content.
