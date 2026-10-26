# LocalFlow vs the meeting-notes market — October 2026

The September table compares dictation tools: [competition-2026-09.md](competition-2026-09.md).
This one compares the meeting side, which is where 0.3.9 and 0.4.0 went.

Vendor claims below were checked against public pages, release notes and official FAQs on
25 October 2026 by a second model (Codex) with web access, and are recorded in Chronicle
under `localflow/product_ml_review_2026_10_25`. They are vendor statements, not measurements.
The LocalFlow column describes 0.4.0 as shipped in this repo.

## Screen context — the feature the owner asked for

| | What is public | Capture | Where it lands |
|---|---|---|---|
| Granola | Snapshots (blog metadata 6 October 2026) | Other people's shared screens during the call | Used inside the notes |
| Circleback | Visual notes (28 May 2026) | Requires a saved meeting video | Separate visual summary |
| Otter | Automatic slide capture; image-aware chat per conversation | Slides during the call | Slides beside the transcript, images answerable in chat |
| Fathom, Fireflies | Video recording | Full video | Video capture alone does not establish that visual content is summarized |
| Anarlog | Understands attached images | Automatic capture unverified | Chat |
| Rewind | Screen and audio capture **disabled 19 December 2025** per the official Limitless FAQ | — | — |
| **LocalFlow 0.4.0** | Reads the screen of the application being recorded, off by default | One frame per 3 s, thumbnail-signature gate, Vision OCR, window titles. Frames and video are never written | Moments carry their own citation ids, so an assertion can cite a document on screen exactly as it cites a sentence. A "Что показывали" section and a screen tab |

Two differences are worth stating plainly. The others capture *someone else's shared screen*;
LocalFlow reads the window it is already recording, which includes the owner's own screen when
the owner is the one sharing. And the others keep the frames — a video or a stored snapshot —
while LocalFlow keeps only recognized text and window titles, so the artefact that leaks if the
archive leaks is a line of text, not a picture of a customer's dashboard.

Not verified here: the pipeline has never been run live. There are no disk, CPU or latency
numbers, and no evidence that Russian text is recognized acceptably off this Mac's screen —
only code that asks Vision which languages it supports before requesting them.

## Summaries

Granola, Circleback, Otter and Fathom all condense with frontier cloud models, and that is the
honest gap: a 9 B local model does not write like one. The 0.4.0 answer is to take the writing
away from the model — the model emits typed assertions tied to turn ids, the document is
assembled in Swift — which is also the architecture the October review recommended. What it
buys is measured in [validation.md](validation.md): on the same 45-minute call, figures that
are actually in the conversation rose from 14 of 25 to 31 of 32, coverage of the conversation's
figures from 13 of 37 to 17 of 37, tasks with a diarizer label as owner from 8 of 8 to 0 of 9.

What it does not buy: a narrative. The document is still a set of typed sections, so the plot of
the conversation is not in it. That is the main remaining gap against the reference summary the
owner approved, and it is the first item below.

## What to do next, in order

1. **A passage per topic.** A fourth stage over the assertions that already exist: group them by
   time and word overlap, let the model do nothing but name the group, and assemble three to
   five sentences per topic in code from the grouped assertions. No new model freedom, no new
   way to invent a figure. Proof: topic coverage and ordering against a hand-written reference
   for the two calls already prepared, plus the existing `summary-quality` metrics unchanged.
2. **First live screen run.** This is the owner's real screen, so the first run is his. It needs a
   meeting he is content to have read, and it produces the numbers the table above is missing:
   journal size per hour, OCR time per frame, whether Russian comes back usable.
3. **Decide the model weight on the harness that now exists.** `summary-ab` compares two paths
   over identical prepared material; the same switch compares two weights. Candidate from the
   October review: Qwen3.5-9B-4bit, ~5,98 GB of weights against Gemma 4 E2B today, on an 18 GB
   machine that also holds Parakeet and the diarizer. Measure extraction accuracy per window,
   not document prettiness, and keep the decision reproducible — that is what the pinned
   `exact: "3.31.4"` dependency is for.
4. **The letter after the call.** The decisions, the task table and the open questions as a draft
   message the owner can send. It is deterministic from records that already exist, it is what
   the paid tools are actually used for, and it adds no new failure mode: if there are no
   records, there is no letter.
5. **The calendar as a name source.** Vocative detection only names people who are addressed by
   name during the call. Reading the local calendar event's participants gives candidates for the
   first call with someone, where there are no vocatives yet. Candidates only — names are still
   applied by hand, as now.
6. **Close the questions that were answered.** "Открытые вопросы" currently holds everything the
   model labelled a question, including ones answered in the next sentence. A question whose
   window contains a later assertion that answers it should leave the section.
7. **Rank sections by what the conversation spent time on**, not by the weight of a single
   record. Today a figure-carrying aside can outrank the topic that took twenty minutes.
8. **Open the archive over MCP**, as the September trajectory already proposed: the owner's own
   calls queryable with citations from any assistant, locally. No competitor offers that without
   sending the transcript somewhere.

Cold start remains a daily-driver defect independent of all of this: 22,69 s for the first replay
in a fresh process against 1,48 s warm, recorded in [validation.md](validation.md).

## Sources

- Granola: https://www.granola.ai/blog
- Circleback: https://circleback.ai/
- Otter: https://otter.ai/
- Fathom: https://fathom.video/ , Fireflies: https://fireflies.ai/
- Limitless FAQ on Rewind capture: https://www.limitless.ai/faq
- MLX Swift LM releases: https://github.com/ml-explore/mlx-swift-examples/releases
- Weight sizes taken from Hugging Face file manifests, 25 October 2026
