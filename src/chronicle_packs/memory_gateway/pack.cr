require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./embedding_service"
require "./backend"
require "./embedders"
require "./behaviors"
require "./tools"

# Memory Gateway Pack — the memory lifecycle: candidate evaluation, storage,
# retrieval, ranking, and reliability. Ported from upstream `packs/memory_gateway`
# (revision 6639a5385518ad49f74813373c85cf96eff9adc0). Slice 1 uses a
# graph-backed store; SQLite/embedding backends, adapters, the promotion
# module, and resolve_memory_query are deferred.
module Chronicle::Packs::MemoryGateway
  include Chronicle::Packs::DSL

  pack(
    name: "memory_gateway",
    version: "0.1.0",
    description: "Decides what to keep, stores accepted memory items, and handles retrieval, ranking, and reliability.",
    settings_schema: MemoryGatewaySettings,
  )
end
