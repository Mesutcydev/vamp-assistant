# Vamp Assistant 0.10.55 (134)

This macOS release bundles the current upstream llama.cpp and Prism compatibility
servers, so automatic updates include GGUF runtime support without a separate
runtime installation. The helper binaries share the app's Developer ID signature.

- LFM3 Omni supports workspace audio transcription/translation, image questions,
  video frames with their soundtrack, and native WAV speech generation.
- Bonsai 2 packed PQ2_0/PTQ1_0 files select Prism by GGUF metadata, including
  renamed imports. Standard Llama, Liquid, and Qwen GGUF architectures select
  the current upstream runtime automatically.
- MLX Swift 0.32.3 and MLX Swift LM 3.32.3 are paired with the required API
  compatibility changes. Existing model files and independent app storage remain
  in place. Memory admission and model-format limits still apply.

File-based media tools are included; continuous microphone/camera conversation
is not part of this release. Video decoding requires ffmpeg in PATH.

Validation: both macOS test bundles compile; 14 headless Swift core tests and
5 installer tests pass. Live Omni audio/video/speech and Bonsai 2 2B PTQ1_0
checks pass. App-hosted XCTest execution remains unverified because Xcode's
runner stalls before test execution. Companion's unchanged-iOS guard passes.

The website DMG and app are Developer ID signed. At the user’s request, Apple
notarization and Sparkle promotion are deferred. No Apple upload completed.
The existing signed Sparkle feed continues to serve the previous notarized build.

Website artifact: `Vamp-Assistant-0.10.55-build-134-preview.dmg` (46,821,326 bytes).
SHA-256: `3c9a938343f84527e56a4384583531af478c6162246bcbc6474d3cd44c10ea0e`.
