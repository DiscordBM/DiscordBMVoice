# Contributing to DiscordBMVoice

All contributions are welcome, but must adhere to the project standards outlined below.

## Semantic Versioning
DiscordBMVoice follows Semantic Versioning 2.0.0, with minor exceptions to keep up with Discord voice gateway and DAVE protocol changes: https://github.com/DiscordBM/DiscordBMVoice#versioning.
Changes that break public API contracts must be scheduled for the next major version.

## Code Style & Concurrency
- **Swift 6 Concurrency**: All code must compile cleanly with Swift 6 strict concurrency enabled (`-require-explicit-sendable`, actor isolation).
- **Code Formatting**: Format code using `swift-format` before submitting (`swift-format format -i --recursive Sources Tests`).
- **Discord Voice Spec**: Keep Discord snake_case property names in gateway payload structs to match Discord's official voice documentation.
- **Real-Time Audio Performance**: Hot loops in audio transmission and mixing (`AudioSender`, `AudioMixer`, `AudioReceiver`) must remain non-blocking and allocation-free in 20ms ticks.

## Testing
Always run the test suite before submitting pull requests:
```bash
swift test
```
