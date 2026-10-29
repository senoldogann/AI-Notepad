---
title: "Recording Teams, Zoom and Google Meet on a Mac: what macOS allows"
description: What macOS lets an app hear during a video call, which permissions it asks for, where to find them in System Settings, and what to check when a recording comes out empty.
author: Senol Dogan
published: 2026-10-29
---

You want a recording of a call, or at least a transcript. You're on a Mac, and the call might be on Microsoft Teams today, Zoom tomorrow and Google Meet on Friday. What can an app actually record, and what does macOS ask you to allow first?

The short version: macOS lets an app hear your microphone and the sound your Mac plays, each behind its own permission. Once both are allowed, the call app doesn't matter much. Here's the longer version.

## Two sources of sound

Every call on your Mac involves two separate streams:

- **Your microphone**, which carries your voice.
- **System audio**, which is everything the Mac plays. The other people on the call arrive here, whether you're using the Teams app, the Zoom app or Google Meet in a browser tab.

To record a whole conversation, an app needs both. With only the microphone, it hears you clearly and the others faintly, if at all (and not at all with headphones). With only system audio, it hears everyone except you.

Because the other people always come through system audio, the same approach works for every call app. Google Meet running in Chrome or Safari is no different from the Zoom app as far as macOS is concerned: it's sound coming out of the Mac.

## Permission 1: Microphone

The first time an app tries to use the microphone, macOS asks you. If you allow it, the app appears in **System Settings › Privacy & Security › Microphone** with its switch turned on.

If you said no, that's where you fix it. Turn the switch on and start the recording again.

While any app is using the microphone, macOS shows an indicator in the menu bar. That's expected.

## Permission 2: System audio recording

Capturing what other apps play is treated as sensitive too, so it has its own permission. You'll find it in **System Settings › Privacy & Security › Screen & System Audio Recording**.

Two details are worth knowing:

1. **An app can ask for the sound without the screen.** This section covers both screen recording and audio-only recording. An app that only needs to hear the call can ask for system audio alone, without being able to see your screen.
2. **Apps can't check this permission in advance.** macOS doesn't tell an app whether system audio recording is allowed until it tries. That's why some apps ask you to press a "test" or "allow" button during setup: it starts a short capture so macOS can show its prompt.

If you denied this one, open the section above and switch the app on there.

## What about the call app's own record button?

Teams, Zoom and Meet each have a recording feature of their own. Whether you can use it often depends on the host, your organisation's settings or your plan, and these recordings are usually announced to everyone in the call.

That's a perfectly good option when it's available. Recording on your own Mac is useful when it isn't: when you're a guest in someone else's meeting, or when your meetings are spread across three different call apps and you want the notes in one place.

## Other ways people record calls

You'll come across two other approaches:

- **Screen recording.** Records the picture and the sound together. It needs screen recording permission and produces large files, which is a lot if all you want is a transcript.
- **Virtual audio devices.** A separate audio driver that you route the call's sound through. It works, but you have to install it and switch your output device, and it's easy to forget to switch back.

Capturing system audio directly avoids both: no video, no extra driver, no changes to your sound settings.

## What doesn't work: the iPhone

On an iPhone, apps can't record the sound of a Teams or Zoom call. iOS doesn't allow one app to capture another app's audio. If you join important calls from your phone, join them from your Mac instead when you need a record.

## How Gistsmith handles it

Gistsmith, the meeting notepad we make, uses exactly these two permissions. It runs on Macs with Apple silicon and macOS 15 or later.

- During setup it asks for the **microphone** (your voice) and **system audio** (the other people). The system audio step starts a short capture so macOS can show its prompt.
- It records the two streams separately, so your lines and everyone else's stay apart, and speakers are separated in the final transcript.
- It leaves its own sound out of the capture. If you play back an earlier meeting while recording, that doesn't end up in the new transcript.
- If your output device changes during a call, for example when AirPods connect, it sets up the capture again. If that fails, it tells you to check the output device and restart the recording.

No bot joins the call, so nothing appears in the participant list. That also means telling people you're recording is up to you; we wrote about [how to do that without making it awkward](/blog/meeting-notes-on-mac-without-a-bot).

## When the recording comes out wrong

Most problems come down to one of the two permissions or the wrong device. Work through this list:

**The transcript only has your voice.** System audio isn't being captured. Check Screen & System Audio Recording in System Settings and make sure your app is switched on.

**The transcript has everyone except you.** Check the Microphone section in System Settings. Then check the input device in **System Settings › Sound › Input**: an external webcam or a disconnected headset may be selected.

**The other people sound doubled or echoey.** You're probably on speakers, and the microphone is picking up the call from the room. Use headphones.

**It worked yesterday and not today.** A macOS update or a new audio device can change things. Open both permission sections, check the switches, and restart the recording.

## The short version

- Two permissions: **Microphone** and **Screen & System Audio Recording**. Both live in System Settings › Privacy & Security.
- With both allowed, a Mac app can record Teams, Zoom and Google Meet the same way, browser or not.
- The call apps' own recording buttons are fine when you're the host and they're turned on.
- iPhones can't record call audio from other apps; use the Mac.
- Always tell the people in the call.
