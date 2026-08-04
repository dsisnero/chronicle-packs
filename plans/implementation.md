# Implementation notes

Adopted rules for behavior-critical decisions, recorded per the chronicle
AGENTS.md guidance ("Record the adopted precedence, tie-break, privacy, or
fallback rule in `plans/implementation.md` and cover it with a
deterministic test").

## Deterministic provider routing (`llm_provider`)

The router — not a channel client, not the model — owns provider/model
selection and ordered fallback (Smista "Combined Router and Log
Principle"; chronicle AGENTS.md). `Chronicle::Packs::LLMProvider` supplies
the configured provider and its deterministic target; it never routes.

Adopted rules:

- **Resolution precedence**: explicit `LLMProviderSettings.provider` wins
  over the environment, including on conflict. Otherwise the env fallback
  probes `ANTHROPIC_API_KEY` then `OPENAI_API_KEY`.
- **Tie-break**: when both env keys are present with no explicit setting,
  Anthropic wins (documented tie-break; set `provider` explicitly to
  override).
- **Zero-key floor**: no setting and no env key resolves to `none` — the
  deterministic extraction floor is a supported mode, not an error. In
  this mode `router_target` yields no target.
- **Deterministic model**: each provider has a fixed default model when
  none is configured explicitly (`anthropic` → `claude-sonnet-4-5`,
  `openai` → `gpt-4o-mini`, mirroring `activegraph.llm`), so the provider
  target is fully deterministic.
- **Provider → router target**: `router_target` maps the resolved
  provider to a `Chronicle::Routing::Target` (provider + deterministic
  model, remote). The router's own precedence/fallback rules then apply
  (explicit target override > rule priority/specificity > default;
  ordered fallback filtered by availability and local-only constraints).
  The executor consumes the recorded target and never silently
  substitutes a model.

Deterministic tests: `spec/chronicle_packs/llm_provider_spec.cr`
(`deterministic router integration`).
