<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" height="128" alt="AI-Notepad icon">
</p>

<h1 align="center">AI-Notepad</h1>

<p align="center">
  A native macOS meeting notepad: live Finnish/English transcription, optional Turkish translation,
  and a Turkish post-meeting note that starts with <b>what you have to do</b>.
</p>

---

## Features

- **Live transcript** of both sides of a call: your microphone ("You") and the computer's audio
  (the other participants), with speaker separation.
- **Only the other side, if you want:** turn off "Also record my voice" and the microphone is never opened.
- **Optional live Turkish translation** in a floating glass panel and a notch "island".
- **Post-meeting note in Turkish:** your tasks first, then decisions, summary and a glossary.
  Long meetings (hours) are processed part by part, so no task gets lost.
- **Meeting library:** search, a Spotify-style player that highlights the spoken word, PDF/Markdown export,
  speaker naming, merging and AI suggestions ("Review speakers").
- **Assistant during the meeting:** "What did I miss?" and free questions about the conversation.
- **Ask your meetings:** questions across all notes and Finnish/English transcripts, answered in Turkish
  with links to the source meetings.
- **Speakers recognised by voice (off by default):** name someone once and they are named in later meetings.
  Voiceprints are biometric data: when on, a print of everyone who speaks for more than 8 seconds is stored with the
  meeting, and named people are remembered on this Mac. Deleting a meeting forgets what was learned from it; deleting
  its audio removes its prints. Ask participants before turning this on. People pages show each person's meetings,
  talk time and tasks.
- **Calendar:** upcoming meetings on Home, a notification one minute before with "Start listening", a suggestion
  when another app turns on the microphone; recordings take the event's title and attendee names.
- **Tasks:** tick tasks off, see open and done tasks, send them to Apple Reminders.
- **Sharing:** note templates (one-on-one, client, lecture, interview, your own), a Finnish or English version of
  the note for colleagues and the macOS share menu.
- **In-person mode:** everyone on the microphone is separated into speakers.
- **MCP server:** `AINotepad --mcp` lets Claude Desktop, ChatGPT and other MCP clients list, search and read your
  meetings (read-only). What the client reads is sent to that client's AI provider.
- **Agent Skill for Claude:** [`skills/ai-notepad-meetings`](skills/ai-notepad-meetings/SKILL.md) teaches Claude how to
  use the MCP server (weekly review, follow-up email, meeting prep). Skills written for other tools can be imported in
  Settings › Connections and run in Ask with `/`.
- **Send notes and tasks:** Slack, Microsoft Teams, Discord, Zoom Team Chat, Notion, Apple Notes, a Markdown folder and
  any webhook (Zapier, Make, n8n) — several at once, each with its own automatic sending. Tasks go to Linear or Jira.
  Slack/Teams/Discord sign in with OAuth + PKCE; Notion, Linear and Jira through their official MCP servers with
  dynamic client registration, so no API keys are pasted.
- **No keys needed, if you prefer:** on-device WhisperKit plus a local Ollama model, detected in one click.
- **Engines:** Deepgram + ElevenLabs in the cloud (gaps in the live transcript are filled from ElevenLabs), or
  fully on-device WhisperKit + SpeakerKit.
  LLM: Claude (default Claude Haiku 5.5) or any OpenAI-compatible server (OpenAI, Ollama, …).
- **iPhone app:** records in-person meetings with live text and Turkish translation, a Live Activity on the Lock
  Screen and Dynamic Island, Shortcuts and a Control Center button; reads, plays and searches your meetings.
- **iCloud sync (opt-in):** finished meetings move to your iCloud Drive and appear on both Mac and iPhone; keys can be
  sent to the iPhone through iCloud Keychain. Off by default: meetings stay in
  `~/Library/Application Support/AINotepad`.
- **Privacy:** a reminder to tell participants you are recording; API keys live only in the Keychain. With the cloud
  engine, audio is sent to Deepgram (live) and ElevenLabs (speaker windows during the meeting and the full recording
  afterwards, so roughly three times in total), and the transcript goes to your LLM provider; the on-device engine
  keeps audio on your Mac. Audio files are deleted after the retention period you choose (failed or interrupted
  meetings after twice that period, so they can still be reprocessed).
- English and Turkish user interface.

## Install

1. Download the latest `AI-Notepad-<version>.dmg` from [Releases](../../releases).
   The app is signed with a Developer ID and notarized by Apple.
2. Drag **AINotepad** to **Applications** and open it.
3. Follow the setup page: grant microphone and system-audio permissions and add your API keys
   (Deepgram, ElevenLabs, Anthropic — or choose the on-device engine and an OpenAI-compatible LLM).

Requirements: macOS 26 or later on Apple Silicon.

## Build from source

```bash
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # put your DEVELOPMENT_TEAM here
xcodegen generate
xcodebuild -project AINotepad.xcodeproj -scheme AINotepad -configuration Debug \
  -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' build
scripts/install-app.sh          # Release build into /Applications (permissions persist)
```

Tests (Swift Testing):

```bash
swift test --package-path Packages/AINotepadCore                          # fast tests
AINOTEPAD_CLOUD_TESTS=1 swift test --package-path Packages/AINotepadCore  # + real Deepgram/ElevenLabs/Claude calls
```

Cloud tests read keys from the Keychain service `AINotepad`. Distribution builds are produced with
`scripts/release.sh` (Developer ID signing, notarization, stapled DMG).

Project layout: all logic lives in the Swift package `Packages/AINotepadCore` (with its tests);
`App/` contains only the SwiftUI/AppKit interface. Design notes are in `docs/superpowers/specs/`.

## Türkçe

AI-Notepad, Fince/İngilizce toplantıları canlı yazıya döken, istersen Türkçeye çeviren ve toplantı sonunda
**sana düşen görevlerle başlayan** Türkçe not hazırlayan bir macOS uygulamasıdır. Kurulum için
[Releases](../../releases) sayfasından DMG'yi indir, uygulamayı Uygulamalar klasörüne sürükle ve kurulum
sayfasındaki adımları izle. Anahtarlar yalnızca macOS Keychain'de, kayıtlar yalnızca Mac'inde tutulur.

## License

[Apache License 2.0](LICENSE) — see also [NOTICE](NOTICE).
