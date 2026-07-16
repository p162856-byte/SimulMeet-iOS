# SimulMeet iOS

Native SwiftUI simultaneous interpretation and meeting assistant for iOS 16+.

- Apple Speech microphone transcription
- complete-sentence queue with 35-second near-duplicate suppression
- Doubao Seed 1.6 Flash / Doubao Seed 2.0 Mini / DeepSeek V4 Flash switching
- Simplified Chinese live translation
- manual bilingual Q&A and meeting summaries
- local history, materials and token usage
- auto-follow history only while the user remains at the bottom
- API keys stored in Keychain

Open `SimulMeet.xcodeproj` in Xcode, select a signing team, connect an iPhone and Run.

To create an unsigned IPA for a third-party IPA signing tool, run
`build_unsigned_ipa.command` on macOS or trigger the included GitHub Actions workflow.

See `iOS安装与使用说明.txt` for Chinese installation instructions and iOS audio limitations.
