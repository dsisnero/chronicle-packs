# PR workflow

## Before opening a PR

1. Compare the change to the pinned vendor source and its tests or fixtures.
2. Run all quality gates:
   `crystal tool format --check src spec`, `ameba src spec`, `crystal spec`,
   and `crystal build --no-codegen src/chronicle-packs.cr`.
3. Update `plans/parity.md`, `plans/inventory/python_port_inventory.tsv`, and
   `plans/inventory/python_test_parity.tsv` whenever a parity status changes.
4. Commit feature ports in focused, atomic commits with a `port:` prefix.
   Documentation-only changes may use `docs:`.

## PR checklist

- [ ] All upstream-equivalent tests pass.
- [ ] `crystal tool format --check src spec` passes.
- [ ] `ameba src spec` passes.
- [ ] `crystal build --no-codegen src/chronicle-packs.cr` passes.
- [ ] Vendor-source and vendor-test evidence is included in the PR description.
- [ ] Parity roadmap and both inventories are up to date when the change
      affects vendor coverage.
