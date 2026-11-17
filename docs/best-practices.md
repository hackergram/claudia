# Best practices

Working conventions for development runs in the `/xpal-src` workspace —
whether the run is a person at the keyboard or an agent working on their
behalf. These are practices, not design decisions; a decision with real
trade-offs belongs in an ADR (`docs/decisions/`).

## End every dev run on something a human can test

**A run is not finished when the tests pass. It is finished when a person can
try the thing and see for themselves whether it works.**

Unit tests tell you the logic is consistent with itself. They do not tell you
the feature works in the environment it is for. A run that ends on "all green"
with nothing the user can touch pushes the first real test onto them, later,
without a clear way in — and it hides the most likely place for a surprise.

### What "human-testable" means

The run's final message gives the person a **try it** block they can follow
without reading the diff:

| | |
|---|---|
| **Try it** | The exact command(s), copy-pasteable, in order. |
| **Needs** | What must be true first, and *where*: what must be running, on the host or in the container, which credentials or services. |
| **Expect** | What they should see if it works, and what a failure looks like. |
| **Verified** | What was actually run, and how (unit tests, a live run, a smoke script). |
| **Not verified** | What was *not* exercised, and why. Never blur this into "should work". |
| **Clean up** | How to undo or remove anything the test creates. |

If the run can only be tested against something that is not available (a
service is down, a device is absent), the run still ends on a human-testable
thing: the script or steps that *will* test it, written and committed, clearly
marked **unrun**, with the single step that unblocks it. "Written but never
run" is an honest state; "done" is not.

### How to get there

- **Cut vertical slices, not horizontal layers.** Build the thinnest path a
  person can exercise end to end — one command that really does the thing —
  before widening it. Three finished layers with nothing runnable is a worse
  stopping point than one narrow slice that runs.
- **Stop at the first testable point** and hand over, rather than pressing on
  to the next layer. The person's feedback on a real slice is worth more than
  more unverified code on top of it.
- **Keep a smoke path.** Anything touching a real system (a browser, a
  container, an API) gets a short opt-in script that exercises it for real,
  next to the unit tests. It exits with a distinct code when the environment
  is absent, so "could not run" is never reported as "passed".
- **Make the first test safe.** Default to fixtures, throwaway data and
  isolated state, and make destructive or outward-facing steps explicit. A
  human should be able to try it without worrying about what it touches.
- **Say what changed on disk.** If the run installs, links or writes anything
  outside the repo, say so in the handoff, and clean up temporary scaffolding
  that was only needed to test.
- **Leave the repo in a state they can run.** Committed (or clearly staged),
  no half-applied edits, and install or reinstall steps stated if the thing
  under test runs from an installed copy rather than the checkout.

### What not to do

- Do not end on a green test run and call the feature done when it has never
  been exercised in its real environment.
- Do not report something as verified because it *should* work. If it was not
  run, it goes under **Not verified**.
- Do not hide an unmet precondition in the middle of a long summary. If the
  person has to do something first, it is the first thing in **Needs**.
- Do not quietly work around a missing environment (borrowing credentials,
  starting services you were not asked to, faking the dependency) to get a
  green result. Report the blocker instead.

### Example

> **Try it**
> ```
> ophio attach
> ophio record start --out expense.workflow.jsonl
> # ...use Chrome normally...
> ophio record stop && cat expense.workflow.jsonl
> ```
> **Needs:** Chrome on the host with the debug port open (`ophio host-cmd`),
> and `./install.sh --no-npm` run so the installed copy has `record`.
> **Expect:** a red "ophio recording" badge in the tab; a JSONL file with a
> `goto`, your fields as `{{params}}`, and no password value anywhere.
> **Verified:** 19 unit tests, including a hostile payload carrying a password.
> **Not verified:** the page-side script in a live Chrome; `tests/smoke.sh`'s
> recording section is written but unrun.
> **Clean up:** delete the workflow file; `ophio close`.
