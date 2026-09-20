# TypeSafe Guardrails

Opt-in additional safety layer that asks [TypeSafe](https://docs.typesafe.ai)
System One (Jev) questions at two points in the agent loop. It is **not** a
chat model and never becomes one: TypeSafe answers typed questions with
probabilities, so it cannot appear in the model picker or serve a
conversation.

## What it does

| Guardrail | Where it runs | What happens |
|---|---|---|
| **Content screening** | After a tool whose output comes from outside the workspace executes, before the observation enters the model context | Untrusted text is judged for agent-directed instructions and credential bait. Flagged content is wrapped in `<untrusted_content>` with the verdict, and instruction-like lines are redacted. |
| **Command escalation** | Only where the permission gate would have acted silently (`.auto`, i.e. Auto-approve or Full Access) | A "destroys or irreversibly modifies data / acts outside the project" verdict turns the call into an approval card, with the reason in the transcript. |

Both are additive on purpose:

* The guard can never approve anything, never relax `CommandPolicy`, never
  suppress or rewrite a tool result into something the tool did not return,
  and never downgrade `.needsApproval` or `.denied`.
* Every failure path — no key configured, offline, 429/529/503, unreadable
  answer, missing answer id — returns **no verdict** and the loop behaves
  exactly as it did before.
* The deterministic `PromptInjectionSanitizer` stays the floor: when TypeSafe
  has no verdict, its findings still label untrusted observations.

## Where it lives

| Piece | File |
|---|---|
| HTTP client (`POST /v1/systemone`, `GET /v1/models`, retries with backoff) | `Core/TypeSafe/TypeSafeClient.swift` |
| Question/answer types and error taxonomy | `Core/TypeSafe/TypeSafeTypes.swift` |
| Keychain-backed API key | `Core/TypeSafe/TypeSafeKeyStore.swift` |
| The judgements (screening + escalation) and their thresholds | `Core/TypeSafe/TypeSafeGuard.swift` |
| Loop integration | `Core/Agent/AgentLoop.swift` (`screenUntrustedOutput`, `typeSafeEscalation`) |
| Tool trust flag | `AgentTool.untrustedOutput` (declared in the protocol body so it dispatches dynamically) |
| Settings + UI card | `SettingsStore.typeSafe*`, `App/SettingsTypeSafeCard.swift` (Providers tab) |
| Event → transcript/diagnostics | `AgentEvent.guardrail(GuardrailNotice)`, `AgentSessionController.handle` |

## Configuration

Settings → Models & Providers → Providers → **TypeSafe Guardrails**.

* **API key** — stored in the Keychain under `com.beetcode.typesafe`
  (`api-key`), never in UserDefaults or session files. "Test connection"
  validates it against `GET /v1/models`.
* **Model** — pinned to a versioned id (`jev-1.13.0`) by default. The
  `jev-latest` alias has served transient `503 model_unavailable` responses
  while the versioned id answered moments later; the response's `model` field
  is what actually answered and is recorded in the guardrail notice.
* **Screen untrusted content** (default off)
* **Escalate destructive actions** (default off)
* **Thresholds** — probability above which a verdict counts as flagged /
  escalated (default `0.70`). Screening and escalation have separate
  thresholds.

## Billing and latency

Billing is **input tokens only** ($0.042 per Mtok; output tokens are free).
A screening call sends the first 8 000 characters of one observation plus two
short questions — a few thousandths of a cent per page. Only the head of a
document is screened, and text shorter than 24 characters is skipped without
a network call.

## Tests

`Tests/TypeSafeTests.swift` covers the client (batching, retry/`retry-after`,
typed errors, malformed responses), the guard (thresholds, offline → no
verdict, short text → no call, missing answer → no verdict) and the loop
(escalation forces an approval card under Auto and Full Access, a clean
verdict leaves auto-approve intact, flagged page content is labeled and
redacted, the local scan still labels when TypeSafe is unavailable, screening
off changes nothing, workspace files are never screened). All deterministic —
a stub transport stands in for the network.
