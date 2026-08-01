# Testing

## Running tests

```bash
crystal spec
```

## Test layout

- `spec/` mirrors the ported pack structure, one spec file per pack/feature.

## Parity

Tests are behavior-faithful ports of upstream `activegraph-packs` tests and
fixture scenarios. Where upstream lacks tests, write characterization specs
from observable behavior and mark inferred behavior clearly. Do not weaken
assertions or change fixtures just to fit the current Crystal implementation.

## Upstream test index

Upstream tests live in `vendor/activegraph-packs/tests/`; the parity manifest
`plans/inventory/python_test_parity.tsv` tracks 558 upstream tests.
