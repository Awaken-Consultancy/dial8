<div align="center">
  <img src="assets/icon.png" alt="Dial8 Icon" width="120" height="120">
  
  # Dial8 - Local Speech-to-Text for macOS

  **Default engine: Parakeet** — built for speed on Apple Silicon. **Hotkeys that adapt** — tap, hold, or toggle; your choice.
</div>

Dial8 is built around **Parakeet** as the primary experience: ultra-fast, on-device speech recognition that runs on the **Neural Engine**, with models you download once and keep local. Need broader language coverage? Switch to **Whisper** (whisper.cpp) in settings for deep multilingual accuracy. No cloud API for transcription, no account—just speak, and text lands in the app you’re using.

## Key Features

### 🦜 Parakeet — the main event

Dial8 ships with **Parakeet** as the default engine because it is tuned for real daily use on Apple Silicon:

- **Neural Engine** execution for responsive, low-latency transcription
- **Speed-first** — ideal when you want dictation to feel as immediate as typing
- **25+ European languages** with strong out-of-the-box quality
- **On-device only** — model downloads to your Mac; inference never leaves the machine

Whisper remains available when you need **99+ languages** (including many Asian languages) or maximum flexibility—pick the engine per workflow in settings.

### ⌨️ Hotkeys that actually match how you work

The hotkey system is designed so **one key** can do different things depending on *how* you press it—no more fighting the app to get “hold to talk” vs “tap to toggle.”

- **Smart (hybrid)** — *short tap* starts or stops recording; *hold and release* behaves like classic **push-to-talk**. Best of both worlds in a single shortcut.
- **Push to talk only** — hold to record, release to finish; predictable when you always want press-and-hold.
- **Toggle only** — press to start, press again to stop; great when you don’t want to hold a key.
- **Left / right Option** — when your hotkey uses **⌥**, you can require **left** or **right** Option only, so the other Option stays free for other apps.
- **Space to lock** — while recording, hit **Space** to **lock hands-free** mode so you don’t have to keep the hotkey down.

Pair these with **Manual** vs **Streaming** recording (pause-based segments for long dictation) in settings.

### 🎯 Smart Voice Activity Detection
- Only transcribes when you're actually speaking
- Filters out background noise (TV, music, conversations)
- Visual feedback shows when speech is detected via HUD effects

### 🔉 Audio Ducking

- Lowers system output volume while you record so media or speakers interfere less with your voice and transcription quality; volume is restored when recording stops

### 🎚️ Microphone Selection

- Pick your input device explicitly; improved device detection and switching when you change audio hardware

### 🤖 AI-Powered Text Processing
- Leverages macOS 15's foundation models
- Rewrite transcribed text in different tones
- Multiple tone options available

### 🔐 Privacy First
- Transcription runs on your Mac with downloaded local models (no cloud API for speech)
- No sign-in, accounts, or subscription—removed in favor of a fully local workflow
- Your speech stays on the device

### ⚡ Native macOS Integration
- Seamless text insertion into any app
- App-aware functionality
- Accessibility API integration
- System-wide hotkey support

## Installation

### Download Pre-built App

1. Download the latest release from [dial8.ai](https://www.dial8.ai/)
2. Open the DMG and drag Dial8 to Applications
3. Launch Dial8 and grant necessary permissions:
   - Microphone access
   - Accessibility permissions
   - Dictation permissions

### Building from Source

To run Dial8 locally on your Mac:

1. **Clone the repository**
   ```bash
   git clone https://github.com/your-username/dial8-open-source.git
   cd dial8-open-source
   ```

2. **Open in Xcode**
   ```bash
   open dial8.xcodeproj
   ```

3. **Configure signing**
   - Select the project in Xcode
   - Go to "Signing & Capabilities" tab
   - Select your development team
   - Xcode will automatically manage the provisioning profile

4. **Select the target**
   - Choose "dial8 MacOS" scheme from the dropdown
   - Select your Mac as the destination

5. **Build and run**
   - Press `⌘R` or click the Run button
   - The app will build and launch automatically

## Usage

1. **Start with Parakeet** (default) — download the model on first run, then dictate. Switch to Whisper in settings if you need a different language set.
2. **Tune hotkeys** — pick **Smart (hybrid)** if you want both tap-to-toggle and hold-to-talk; otherwise choose pure push-to-talk or toggle. Set **left/right ⌥** if you use Option and need the other side free.
3. **Set your hotkey** in Settings (default: Option key)
4. **Select input device** if you use more than one microphone
5. **Choose Manual or Streaming**:
   - **Manual** — segments follow your activation mode (tap/hold/toggle)
   - **Streaming** — pause-based chunks; stop with the hotkey again

## Building from Source

```bash
# Clone the repository
git clone https://github.com/your-username/dial8-open-source.git
cd dial8-open-source

# Open in Xcode
open dial8.xcodeproj

# Build for macOS
xcodebuild -scheme "dial8 MacOS" -configuration Release build
```


## Contributing

We're building a community around Dial8 to take speech-to-text to the next level! Here are some exciting areas for contribution:

### 🚀 Future Features We'd Love Help With

- **Whisper C++ implementation** - Switch from executable to native C++ implementation for iOS compatibility
- **Real-time streaming transcription** - Like native macOS dictation
- **App-specific configurations** - Automatically adjust tone/style based on the active app
- **Custom tone profiles** - Define your own rewriting styles
- **Voice commands** - Control formatting and punctuation with speech
- **Integration APIs** - Connect with other productivity tools

### How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Guidelines

- Follow existing Swift/SwiftUI patterns
- Add tests for new features
- Update documentation
- Keep privacy and offline-first principles

## Technical Stack

- **Language**: Swift/SwiftUI
- **Speech (primary)**: **Parakeet** via FluidAudio — Neural Engine, on-device
- **Speech (alternate)**: **Whisper** via whisper.cpp — broad language coverage
- **Platforms**: macOS 14+, iOS support in progress
- **Key Frameworks**: AVFoundation, Accessibility, Speech

## Credit: Hanzhi

**Dial8’s recent direction—Parakeet as the default path, a much smarter hotkey model (hybrid / push-to-talk / toggle, Option side selection, hands-free lock), audio ducking, and microphone handling—is driven in large part by [Hanzhi](https://github.com/hanzhi227)**. The project benefits enormously from sustained work on the macOS audio pipeline, speech stack integration, and interaction design so dictation feels natural instead of fiddly.

If Dial8 saves you time every day, **Hanzhi** is a big reason the experience got there. Thank you, Hanzhi, for the architecture decisions, the polish, and pushing the app toward fast local speech and hotkeys that behave the way users expect.

## Community

- [Discord](https://discord.gg/3uYF2f2V) - Join our community chat
- Check the Projects section for current work and how to contribute

## License

[MIT License](LICENSE) - See LICENSE file for details

## Acknowledgments

- **[Hanzhi](https://github.com/hanzhi227)** — lead credit for Parakeet integration, hotkey and activation UX, macOS audio work, and the overall push toward a faster, more ergonomic local dictation experience (see [Credit: Hanzhi](#credit-hanzhi) above).
- [OpenAI Whisper](https://github.com/openai/whisper) for the speech recognition model
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for the efficient C++ implementation
- [FluidAudio](https://github.com/FluidInference/FluidAudio) / Parakeet for fast on-device recognition on Apple Silicon
- All our contributors and community members

---

<div align="center">
  <img src="assets/icon.png" alt="Dial8 Icon" width="80" height="80">
  
  Built with ❤️ by the Dial8 community — with deep thanks to **Hanzhi** for Parakeet, hotkeys, and so much of the macOS experience. Let's revolutionize how we interact with our computers through speech!
</div>
