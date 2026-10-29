---
title: How to take meeting notes on a Mac without a bot joining the call
description: Bots in the participant list make calls awkward. Here's how your Mac can hear both sides of a meeting on its own, and how to tell people you're recording.
author: Senol Dogan
published: 2026-10-29
---

A lot of note-taking tools work by sending a bot into your call. It shows up as an extra participant with a name like "Notetaker", someone has to admit it from the waiting room, and at least one person asks what it is. Some companies block these bots outright. With clients, the bot can set an odd tone before you've said a word.

There's a simpler way. Your Mac already hears the whole meeting: the other people come out of its speakers or headphones, and your voice goes in through the microphone. A note app on your Mac can capture those two sources directly, so nothing new appears in the call.

This guide explains how that works, what macOS asks you to allow, and how to handle the part a bot used to do for you: letting people know they're being recorded.

## What your Mac can hear

During a call there are two separate streams of sound:

1. **Your microphone.** This is you, and anyone in the room with you.
2. **System audio.** This is everything your Mac plays, including the other people on Zoom, Microsoft Teams or Google Meet.

An app that records both has the full conversation. It doesn't matter which call app you use, or whether the call runs in a browser tab. If you can hear the person, the Mac is playing their voice, and the app can capture it.

Keeping the two streams apart has a useful side effect. The app knows which lines came from your microphone, so it can tell your words from everyone else's. That matters when you want a list of what *you* agreed to do.

For a meeting in a room with no call at all, the microphone alone is enough.

## The two permissions macOS asks for

macOS doesn't let an app listen quietly. The first time an app tries, you'll see a prompt for each of these:

- **Microphone.** You'll find it later in System Settings › Privacy & Security › Microphone.
- **System audio recording.** This lives under System Settings › Privacy & Security › Screen & System Audio Recording. An app can ask for the sound only, without recording your screen.

If you clicked "Don't Allow" by mistake, open those sections and switch the app on. There's no need to reinstall anything.

A practical tip: wear headphones if you can. With speakers, your microphone also picks up the other people's voices from the room, and the recording gets an echo of them. Headphones keep the two streams clean.

## How this compares with a bot

The bot approach has some real advantages. It can join a meeting you aren't attending, and everyone sees it, so nobody can miss that the call is being recorded.

The local approach is different in a few ways:

- **Nothing joins the call.** No waiting room, no extra name, nothing for the host to approve.
- **It works with any call app.** Zoom, Teams, Meet, a browser-based tool from a client: they all play sound through the same Mac.
- **It also works in person.** The same app records a meeting in a room.
- **You have to be there.** The Mac only hears the meetings it's in.
- **Nobody sees an indicator.** This is the important one, and it brings us to consent.

## Tell people you're recording

When a bot joins, the bot does the announcing. When your Mac records, that job is yours. In many places it's also a legal requirement, and the rules differ: some require only one person's consent, others require everyone's. If you're not sure what applies to you and the people you meet, check before you start.

Even where the law is relaxed, telling people is simply good manners. A few habits make it easy.

**Say it at the start.** Before the agenda, one sentence is enough:

> Quick note before we start: I'm recording this on my Mac so I can take proper notes. The recording stays with me. Tell me if you'd rather I didn't.

**Put it in the chat too.** People who join late miss the spoken version. A short line in the meeting chat covers them and leaves a written record that you asked.

**Mean the offer to stop.** If someone objects, stop recording and take notes by hand. It happens rarely, and handling it well builds more trust than the notes are worth.

**Pause for sensitive parts.** If the talk turns to something personal or confidential, offer to pause the recording, and pick it up again afterwards.

**Share what you made.** Sending the notes or the task list after the meeting shows people what the recording was for. It turns "they're recording us" into "they sent us a useful summary".

Gistsmith, the app we make, can remind you to tell participants when a recording starts. It's a nudge, not a guarantee: the conversation is still yours to have.

## A short checklist

Before your next call:

1. Install your note app and allow the microphone and system audio recording when macOS asks.
2. Do a two-minute test call with a colleague. Check that the transcript shows both your voice and theirs.
3. Plug in headphones.
4. Prepare your one-sentence recording notice and keep it somewhere you can paste it.

During the call:

1. Start recording before the conversation gets going.
2. Tell people, out loud and in the chat.
3. Pause if the topic turns sensitive.

After the call:

1. Read through the notes while the meeting is still fresh.
2. Send the summary or the tasks to the people who were there.

## When something doesn't work

If the transcript has only your voice, the app probably doesn't have system audio permission. Check Screen & System Audio Recording in System Settings.

If it has everyone except you, check the Microphone section, and make sure the right input device is selected in the Sound settings.

If the app can't capture system audio after you switch output devices, for example when AirPods connect, stop and restart the recording. It's rare, but it's the fastest fix.

That's all a bot-free setup needs: two permissions, a pair of headphones and a sentence at the start of the call.
