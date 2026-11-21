# DiscordBMVoice

[![Documentation](https://design.vapor.codes/images/readthedocs.svg)](Playbook/README.md)
[![Team Chat](https://design.vapor.codes/images/discordchat.svg)](https://discord.gg/kxfs5n7HVE)
[![Apache 2.0 License](https://img.shields.io/badge/license-Apache_2.0-87ceeb.svg?style=plastic&logo=apache&logoColor=white)](LICENSE)
[![Continuous Integration](https://img.shields.io/github/actions/workflow/status/DiscordBM/DiscordBMVoice/tests.yml?event=push&style=plastic&logo=github&label=tests&logoColor=%23ccc)](https://github.com/DiscordBM/DiscordBMVoice/actions/workflows/tests.yml)
[![Swift 6.2+](https://design.vapor.codes/images/swift62up.svg)](https://swift.org)

DiscordBMVoice is a voice library for [DiscordBM](https://github.com/DiscordBM/DiscordBM), written in Swift. It provides Voice Gateway connectivity, audio streaming, and audio playback for Discord bots.

The library provides:
* Direct gateway integration with DiscordBM via `bot.bind(to: voiceManager)` and `channelID.joinVoice()`.
* Audio decoding (MP3, WAV, FLAC) and Opus encoding.
* Playlist queues with track navigation, sub-second seeking (`seek(to:)`), and metadata tracking.
* Concurrent multi-track audio mixing for simultaneous music, sound effects, and speech.
* Inbound 20ms Float PCM audio streaming for speech recognition and transcription models.
* Swift 6 strict concurrency across all actor pipelines.

For low-level protocols, custom DSP filters, multi-guild worker sharding, and full application code, refer to the [Playbook](Playbook/README.md).

## ⚡ Intents

DiscordBMVoice requires the `GUILD_VOICE_STATES` intent when initializing your gateway manager.

## 📖 Playbook & Examples

The [Playbook](Playbook/README.md) contains end-to-end documentation and reference implementations for voice workflows:

* [01. Getting Started & Voice Lifecycle](Playbook/01-GettingStarted/README.md) - Setup, gateway binding, voice state transitions, and configuration options.
* [02. Slash-Command Music Bot](Playbook/02-BasicMusicBot/README.md) - Complete music bot with queue playback, seeking, metadata tracking, and interaction helpers.
* [03. Multi-Track Mixer & Soundboard](Playbook/03-MultiTrackMixerAndSoundboard/README.md) - Concurrent tracks, SoundboardCache RAM preloading, and auto-ducking.
* [04. Audio Filters & Auto-Ducking](Playbook/04-AudioFiltersAndDucking/README.md) - Real-time Float PCM DSP, soft limiting, and Voice Activity Detection (VAD).
* [05. Inbound Audio & AI Transcription](Playbook/05-InboundAudioAndTranscription/README.md) - Decrypted Opus and 20ms Float PCM streaming for speech-to-text.
* [06. Vapor & Web Services Integration](Playbook/06-VaporAndWebServices/README.md) - Shared EventLoopGroup and REST API voice triggers.
* [07. High-Scale Multi-Guild Audio Scheduler](Playbook/07-HighScaleAudioScheduler/README.md) - Worker pool guild sharding and 20ms continuous pacing.
* [08. Protocol Internals](Playbook/08-DAVEProtocolDeepDive/README.md) - MLS state machines, AEAD transport ciphers, and RTP serialization.

### 💬 Community

For discussion, questions, and support, join the [DiscordBM Discord Server](https://discord.gg/kxfs5n7HVE).

### 🛠️ Contributing

Contributions and bug reports are welcome:
* To propose a feature or report an issue, please [open an issue](https://github.com/DiscordBM/DiscordBMVoice/issues/new) or discuss it on [Discord](https://discord.gg/kxfs5n7HVE).
* If you identify a security vulnerability, please contact [security-reports@mahdibm.com](mailto:security-reports@mahdibm.com).

### 📄 About & License

DiscordBMVoice is built for the [DiscordBM](https://github.com/DiscordBM/DiscordBM) ecosystem. Released under the [Apache 2.0 License](LICENSE).
