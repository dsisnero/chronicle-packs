require "chronicle"

require "./settings"
require "./object_types"
require "./relation_types"
require "./behaviors"
require "./tools"

# Chat Adapter Pack — interactive chat input/response adapter. Ported from
# upstream `packs/chat` (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
# Translates chat_input into channel-neutral CommMessage objects, manages
# ChatSession/ChatTurn lifecycle, and delivers assistant responses (via the
# shared LLM behavior pipeline) back to the chat interface.
module Chronicle::Packs::Chat
  include Chronicle::Packs::DSL

  pack(
    name: "chat",
    version: "0.5.0",
    description: "Chat adapter pack. Translates chat input into CommMessage(channel=chat). chat_ingester maps raw {'role': 'user', 'content': '...'} input into CommMessage + ChatSession + ChatTurn. chat_llm_responder assembles context and produces CommResponseCandidate. chat_responder delivers the response.",
    settings_schema: ChatSettings,
  )

  # Rebuild the responder with behavior-scoped gateway proxy tools. Mirrors
  # upstream `build_pack(llm_tools=..., max_tool_turns=...)`: no runtime tool
  # registration occurs after construction.
  def self.build_pack(llm_tools : Array(Chronicle::Tool), max_tool_turns : Int32 = 4) : Chronicle::Packs::Pack
    base = pack
    return base if llm_tools.empty?

    behaviors = base.behaviors.map do |behavior|
      behavior.name == "chat_llm_responder" ? behavior.with_llm_tools(llm_tools, max_tool_turns) : behavior
    end
    Chronicle::Packs::Pack.new(
      name: base.name, version: base.version, description: base.description,
      object_types: base.object_types, relation_types: base.relation_types,
      behaviors: behaviors, tools: base.tools, policies: base.policies,
      prompts: base.prompts, settings_schema: base.settings_schema,
      settings_builder: base.settings_builder, capabilities: base.capabilities,
    )
  end
end
