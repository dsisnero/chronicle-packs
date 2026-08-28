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
end
