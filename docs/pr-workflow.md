# PR workflow

## Before opening a PR

1. Run all quality gates: `crystal tool format --check src spec && ameba src spec && crystal spec`.
2. Update `plans/parity.md` and `plans/inventory/python_port_inventory.tsv` for any new or changed features.
3. Commit feature work in focused, atomic commits with `port:` prefix.
4. Update `CHANGELOG.md` under the unreleased heading.

## PR checklist

- [ ] All upstream-equivalent tests pass.
- [ ] `crystal tool format --check src spec` passes.
- [ ] `ameba src spec` passes.
- [ ] `plans/parity.md` is up to date.
- [ ] `CHANGELOG.md` is updated.
