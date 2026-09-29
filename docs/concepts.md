# Concepts

## The graph is the integration boundary

Chronicle packs share a durable object graph. An object or relation write emits
an event; behaviors registered by loaded packs consume matching events and may
write more graph state. This makes provenance, replay, and cross-pack
coordination observable without a central orchestration layer.

Objects are typed durable nodes. Relations are typed directed edges. Behaviors
are reactive handlers. Tools are callable capabilities, but a model-facing tool
is always a governed gateway proxy rather than a raw provider handler.

## Core and layered packs

`Core` is the smallest shared vocabulary: `source`, `observation`, `task`,
`action`, `artifact`, `memory_candidate`, and `evaluation`, plus their
relations. It deliberately does not own people, organizations, messages,
research claims, or application-specific concepts.

Layered packs own those concepts and connect their outputs back to Core. Add a
new domain concept to the narrowest pack that owns it, then relate it to Core
rather than expanding Core.

## Deterministic floor and model upgrades

The port supports a no-key deterministic baseline. A configured model or
embedding provider may improve extraction or recall, but provider availability
must never erase durable data or make deterministic behavior unavailable.
Recorded completion and embedding seams preserve request/response evidence and
idempotent replay.

## Governance

The Tool Gateway applies policy before an external action. It records the
proposed `capability_call`, evaluates risk and action authority independently,
holds actions requiring approval, and records the eventual result. Action
classes are closed (`R0` through `R4`); only bounded classes can be
auto-approved under an explicit runtime authority ceiling. Secrets remain host
references and are injected only at execution time.

## Evidence and semantic extraction

Importers hand off acquired content. Activity normalization makes provider
input replayable evidence. Semantic extraction produces source-anchored typed
annotations under one provenance envelope; profiles choose extractors by facet.
The guarded request procedure is evaluated in a real fork, falls back on drift,
and demotes after repeated drift rather than claiming equivalence forever.
