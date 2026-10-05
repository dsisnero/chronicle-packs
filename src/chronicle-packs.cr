require "chronicle"

require "./chronicle_packs/copy_with"
require "./chronicle_packs/closed_sets"
require "./chronicle_packs/core"
require "./chronicle_packs/identity_auth/pack"
require "./chronicle_packs/agent_profile/pack"
require "./chronicle_packs/entity/pack"
require "./chronicle_packs/secrets/pack"
require "./chronicle_packs/attention/pack"
require "./chronicle_packs/skills/pack"
require "./chronicle_packs/eval_outcome/pack"
require "./chronicle_packs/semantic_extraction/pack"
require "./chronicle_packs/activity_normalizer/pack"
require "./chronicle_packs/connector_control/pack"
require "./chronicle_packs/usage/pack"
require "./chronicle_packs/tool_gateway/pack"
require "./chronicle_packs/memory_gateway/pack"
require "./chronicle_packs/communication/pack"
require "./chronicle_packs/chat/pack"
require "./chronicle_packs/email/pack"
require "./chronicle_packs/schedule/pack"
require "./chronicle_packs/research/pack"
require "./chronicle_packs/codebase/pack"
require "./chronicle_packs/team_ops/pack"
require "./chronicle_packs/meeting/pack"
require "./chronicle_packs/subject_profile/pack"
require "./chronicle_packs/telegram/pack"
require "./chronicle_packs/whatsapp/pack"
require "./chronicle_packs/composio/pack"
require "./chronicle_packs/gmail/pack"
require "./chronicle_packs/mcp/pack"
require "./chronicle_packs/bridges/pack"
require "./chronicle_packs/evolution/pack"
require "./chronicle_packs/template/pack"
require "./chronicle_packs/local_files/pack"
require "./chronicle_packs/assistant_self_summary/pack"
require "./chronicle_packs/chatgpt_export/pack"
require "./chronicle_packs/claude_export/pack"
require "./chronicle_packs/assistant_local_sessions/pack"
require "./chronicle_packs/public_presence/pack"
require "./chronicle_packs/preflight"
require "./chronicle_packs/manifest_tools"
require "./chronicle_packs/generate_manifests"
require "./chronicle_packs/bundles"
require "./chronicle_packs/llm_provider"
require "./chronicle_packs/doctor"
require "./chronicle_packs/fixtures"
require "./chronicle_packs/demo_server"
require "./chronicle_packs/fixture_runner"

# Crystal port of the ActiveGraph pack library.
#
# The library provides composable packs over a durable, reactive object graph:
# typed objects and relations are facts, behaviors react to their events, and
# tools expose governed capabilities. Start with a bundle:
#
# ```
# require "chronicle-packs"
#
# store, graph, runtime = Chronicle::Packs::Bundles.build_assistant
# ```
#
# See `examples/assistant_chat.cr` and `docs/bundles.md` for a walkthrough.
module Chronicle::Packs
  VERSION = "0.1.0"
end
