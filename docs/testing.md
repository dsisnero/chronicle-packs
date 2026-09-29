# Testing

## Running tests

```bash
crystal spec
```

Run one file or example while iterating:

```bash
crystal spec spec/chronicle_packs/memory_gateway_spec.cr
crystal spec spec/chronicle_packs/memory_gateway_spec.cr -e "retrieval"
```

Specs must remain keyless unless a test explicitly exercises a provider seam.
The deterministic completion and recorded-service test doubles are the normal
baseline; never make a network credential a prerequisite for the suite.

## Test layout

- `spec/chronicle_packs/` mirrors the ported packs and cross-pack features.
- `spec/chronicle_packs/*_spec.cr` contains direct vendor-test ports and
  Crystal characterizations where the vendor assertion crosses a language or
  host boundary.
- `spec/chronicle_packs/fixture_runner_spec.cr` exercises portable fixture
  scenarios. Fixtures test event ordering and durable graph state, not merely
  return values.

## Parity

Tests are behavior-faithful ports of upstream `activegraph-packs` tests and
fixture scenarios. Port the assertion, fixture input, ordering, and failure
mode—not Python syntax. Where upstream lacks a test, write a clearly labeled
characterization spec from observable vendor behavior. Do not weaken
assertions or alter fixtures to fit the current Crystal implementation.

For a capability or provider behavior, assert the durable receipts as well as
the result: gateway policy decision, capability call, approval state, and
result/failure evidence. For memory behavior, test lexical fallback and avoid
assuming an embedding provider exists.

## Upstream test index

Upstream tests live in `vendor/activegraph-packs/tests/`; the parity manifest
`plans/inventory/python_test_parity.tsv` tracks 638 vendor tests: 418 ported,
204 fixture/environment skips, and 16 documented intentional divergences at
the pinned revision. The roadmap in `plans/parity.md` is the authoritative
summary when those counts change.
