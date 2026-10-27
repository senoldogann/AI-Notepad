---
name: ai-notepad-meetings
description: Use the user's AI-Notepad meeting archive (notes, tasks, transcripts) through the AI-Notepad MCP server — weekly reviews, open-task follow-ups, decision lookups and meeting prep. Use when the user asks about their meetings, what was decided, what they owe someone, or wants a recap or follow-up email.
---

# AI-Notepad meetings

AI-Notepad is a local, privacy-first meeting notepad for macOS and iPhone. When it is connected as an MCP server
(AI-Notepad › Settings › Connections › AI apps, or `AINotepad --mcp`), these read-only tools are available:

| Tool | Use it for |
| --- | --- |
| `list_meetings` | Recent meetings with ids, titles, dates; start here to find a meeting. |
| `search_meetings` | Keyword search across titles, notes and transcripts (any spoken language). |
| `get_meeting` | One meeting's full note (summary, decisions, tasks, topic flow) and transcript. |
| `list_my_tasks` | Open tasks assigned to the user across meetings, with the meeting they came from. |

The tools only read. Nothing is changed in the user's archive.

## How to work

1. **Find before you read.** Use `search_meetings` with 1–3 distinctive keywords (names, project names, numbers) or
   `list_meetings` for time-based questions ("this week"). Only then call `get_meeting` for the 1–5 relevant ids.
2. **Prefer the note, fall back to the transcript.** Notes are concise and already in the user's language. Quote the
   transcript only to prove a specific statement, and keep quotes short.
3. **Always cite the meeting** (title and date) for every fact. If something isn't in the archive, say so plainly.
4. **Tasks:** `list_my_tasks` returns only the user's open tasks. Group them by due date, then by meeting.
5. **Language:** answer in the user's language. Meetings may be in Finnish, English or other languages; translate
   quotes and keep names as spoken.

## Recipes

- **Weekly review:** `list_meetings` for the last 7 days → `get_meeting` for each → one section per meeting with
  decisions and the user's tasks, then a short "carry-over" list of open tasks.
- **Follow-up email:** `get_meeting` → draft a short email: thanks, decisions, who does what by when. Do not invent
  dates or owners.
- **Prepare for a meeting with someone:** `search_meetings` with the person's name → summarise what was discussed,
  what was promised by whom, and open questions.
- **Decision lookup:** `search_meetings` with the topic → answer with the decision, the date, and the meeting it came
  from; mention if a later meeting changed it.
