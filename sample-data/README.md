# Sample Data

This folder is the default seed corpus. It describes **Contoso Fleet Telemetry**, a
fictional service, so the example works without access to any real repository and
contains no confidential information.

| File | Purpose in the demo |
| --- | --- |
| `fleet-telemetry-overview.md` | Architecture questions ("What stores the raw events?") |
| `onboarding.md` | Procedural questions ("How do I onboard a new device type?") |
| `troubleshooting.md` | Diagnostic questions ("Why are events delayed?") |
| `faq.md` | Short factual questions and a deliberate gap for "not found" testing |

## How it is used

- The container image copies this folder to `/app/sample-data`. With the default
  `RAG_SOURCE_KIND=local`, both `python -m rag.ingest seed` and the scheduled job read it.
- Each file is split on Markdown headings, embedded, and written to the index with its
  relative path as the citation locator (for example `onboarding.md#register-the-device-type`).

## Questions that should be answered

- "Which service stores raw telemetry and for how long?"
- "What are the steps to onboard a new device type?"
- "Events are delayed by more than five minutes. What should I check?"

## Question that should return "not found"

- "What is the on-call phone number?" — the corpus intentionally does not contain it.

## Replacing the corpus

Point ingestion at your own content instead of editing these files. See
[`../howto/01-seed.md`](../howto/01-seed.md).
