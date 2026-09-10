# Handover, 10 September 2026: Availeth discovery app review and fixes

## What this session did

Stephen asked for a review of everything the Availeth discovery app (the "Timekeeper discovery app") had collected on him since install, what was lacking, and then to fix the main problems. This document records what was found, what changed, and what is still open.

The app is Availeth.app, bundle id com.availeth.discovery, built from this repo on branch `consolidate`. Its data lives in `~/Library/Application Support/Availeth/availeth.sqlite`. Settings are read with `defaults read com.availeth.discovery`.

## What the app had collected (state at 08:34, before any change)

Real capture ran from Monday 8 September 14:49 to Wednesday 10 September 08:34.

| Table | Real rows | Demo rows |
|---|---|---|
| spans | 1,608 | 565 |
| transfers | 67 | 255 |
| minute_summaries | 845 | 14 |
| task_summaries | 43 | 3 |
| idle_sessions | 17 | 4 |
| narratives | 0 | 32 |
| screenshots | 0 | 0 |

Active time 10.66 hours, 35,453 keystrokes, 5,920 clicks. By app: Code 5.57 h, Safari 3.48 h, Outlook 0.79 h, Chrome 0.35 h, everything else under ten minutes.

## What was lacking

1. The screen layer had never run. Screen capture was set to storyline mode but Ollama only had the text model qwen2.5:3b. The vision model qwen2.5vl:7b was never pulled. The engine checked for it every ten seconds, found it missing, and skipped every capture without telling anyone. Every task showed "No screen content was captured for this task. Turn on screen capture in the Privacy tab", which was wrong because capture was on.
2. Storylines were inaccurate. With no screen reads, the 3B text model wrote prose from window titles, keystroke counts and field labels, and it guessed. Examples: "Hotel booking details entry ... switching between Code, Safari and Photo Booth"; a task titled "Email address entry" because the strongest signal was a "To Recipients" label.
3. Titles leaked into the app list. minute_summaries.apps was stored as "App — Title, App — Title" and parsed by splitting on commas, so titles with commas became fake apps: "US News, World News and Videos", "9 September", "the 'Millennium' Math Problem OpenAI Claims to".
4. 174 minutes had no text and 57 minutes belonged to no task.
5. Field labels included junk: "5", "2", "example.com", "Twitter...", a full URL.
6. VS Code exposed no field labels at all. 604 of 715 Code spans had their title cut short with an ellipsis, none had a document path, and 50 of 69 pastes into Code had no field label. Cause: Electron apps build no accessibility tree until a client sets AXManualAccessibility on them.
7. Every verdict was "Not enough evidence" or "Low". The gate is 5 occurrences across 2 days, and Stephen's work is not form filling, so the scoring model does not fit him.
8. Email addresses are stored raw in span titles ("Inbox • sosullivan@navillusinc.com"). Scrubbing only runs on model output.
9. No work/personal split. News, Substack and the Ring of Kerry Hotel booking are summarised the same as payroll work.
10. Outlook shows only "Inbox" or "Drafts", never a subject. Teams meetings barely register.
11. Most of Stephen's day is VS Code driving Claude Code. The app reads that as "typed at length in Code" and has no concept of agent work.

## What changed

Three commits on `consolidate`, tests up from 141 to 161, all passing. The rebuilt app is installed at /Applications/Availeth.app and running.

### fa6935d Say plainly when screen reading cannot run, and stop the story guessing

- New `Sources/Availeth/UI/Coverage.swift`. `CoverageStatus` holds six facts: window titles readable, typing and clicks permitted, screen capture mode, Screen Recording permission, vision model ready, text model ready. `gaps` lists what is missing in order. Screen capture deliberately set to Off is not a gap.
- `AppState` refreshes coverage every two seconds and republishes only on change, so a granted permission or a finished model download clears the banner without a restart.
- `DashboardView`: the old Accessibility-only banner became a general coverage banner. Headline is the first unfixed gap, with a Grant or Install button and a per-gap dismiss.
- `PrivacyView`: a Coverage card under the Discovery card with a check or cross per fact. The banner's Install button scrolls to the Local AI panel.
- `TasksView` and `WorkflowDetailView`: the empty state now says the real reason. For the missing model: "Screen reading is on but no vision model is installed. Install it in Privacy > Local AI."
- New `Sources/Availeth/Analytics/AppList.swift`. Window lists are stored with the ASCII unit separator (U+001F). `parse` reads both the new format and old comma rows, gluing a comma fragment back onto the entry before it unless it carries an "App — " prefix or is a known app name. `StoryWriter.taskRecord`, `Synthesizer` and `StoryView` read through it.
- `Synthesizer.makeTask` asks the text model for prose only when the task has scene narratives. The task-boundary question is asked only when the run of minutes has narratives; otherwise the "apps turn over completely" rule decides. Without narratives the card shows `plainTitle` and `plainStory`.
- `FieldClassifier.isUsableLabel` and `looksLikeWebAddress` in `InputMonitor.swift`. A label is rejected if it has fewer than two letters, is a URL or bare domain, or ends in "..." or "…". Applied at capture time in `CaptureEngine.applyFieldContext` and on read in `Evidence.cleanField`, so old junk is dropped too.

### a36c8ee Throw away a screen read that only repeats the prompt

The first real narrative was "App: Code. Window: Timekeeper clock in behavior. The user just: Switched to Code.", the grounding line handed back. `OllamaInterpreter.isPromptEcho` now rejects a reply that starts with "App:", contains "the user just:", or has fewer than three real words once the app, window and action are removed. Three tests in `PromptEchoTests.swift`.

### 45acc4d Ask Electron apps for their accessibility tree, and stop calling a plain paste an error

- `AXReader.enableAccessibilityIfNeeded` sets AXManualAccessibility and AXEnhancedUserInterface on each process once, behind a lock because it is called from the main thread and the AX queue. Verified: the first Code span after relaunch carried the label "Message input", the Claude Code chat box.
- The Movements caption "no field label in focus" now reads "pasted into the page or editor, not a named field".

### Outside the repo

- Pulled qwen2.5vl:7b (6.0 GB) with `/Applications/Ollama.app/Contents/Resources/ollama pull qwen2.5vl:7b`. The `ollama` command is not on PATH. Narratives started at 08:59:15 and reached 40 by 09:11.
- Memory note `availeth-discovery-app.md` in the Claude memory folder records where the app, repo, data and models are.

## How to verify

```
cd ~/work/taskminor
swift test                      # 161 tests
scripts/build_app.sh            # builds, signs, installs, quits the running app
open -a /Applications/Availeth.app
```

To read the live data without locking it, copy availeth.sqlite plus the -wal and -shm files somewhere first, then use sqlite3. `is_demo = 0` is real activity.

Useful checks:

```
select count(*) from narratives where is_demo=0;
select app_name, count(*), sum(fields<>'') from spans where is_demo=0 and start > strftime('%s','now')-3600 group by 1;
```

The shell used in this session had no Screen Recording permission, so `screencapture` of the app failed. The dashboard banner and Coverage card were not seen on screen, only compiled and reasoned about. Stephen should confirm they render.

## Things to know

- The 43 tasks written before 08:55 keep their old text. Only new work gets the corrected behaviour. Old minute rows are read through the legacy comma parser and are not rewritten.
- Telemetry is set to "deep", which puts the screen reader in detailed mode. Detailed mode keeps on-screen text by design, so narratives contain email addresses and names as written. "Standard" scrubs them.
- The screen capture is of the whole main display minus excluded apps, not the front window. A narrative labelled with one app can describe another app's window that was visible.
- `Permissions.screenRecordingGranted` is read at process launch. After granting in System Settings the app must relaunch.
- The `origin` remote for this repo returned "Repository not found" since 8 September afternoon. These three commits, and the nine before them, are local only. See the memory note `taskminor-repo-access-lost`.
- The build warning in `OllamaService.swift:32` about `sharedPort` predates this session.

## Still open, in priority order

1. Agent-aware work. Treat a Claude Code chat tab as the unit of work, take the repo name from the window title, and count pastes from Safari or Outlook into the chat as "briefing an agent" rather than a chore. This is the product work that matters most for Stephen's own data and for the Availeth pitch.
2. A provisional verdict tier ("looks repetitive, keep watching") with a countdown "seen 3 of 5", and wider mechanical evidence: same page pattern revisited, same shortcut sequence, same file reopened daily.
3. Back-fill or hide the empty placeholder minutes and the minutes assigned to no task.
4. Scrub email addresses from span titles at write time.
5. Per-site exclusions and a working-hours window, so personal browsing is not scored.
6. Read the Outlook message subject and the Teams call title through Accessibility.
7. Build fallback task titles from the strongest signal (top page pattern, top field label, document name) instead of the app list.
8. Consider a larger text model for task summaries and boundaries now that narratives exist. The 3B model is fine for a one-line minute entry.
9. Check that the coverage banner and Coverage card render correctly in both themes. Not seen on screen this session.
