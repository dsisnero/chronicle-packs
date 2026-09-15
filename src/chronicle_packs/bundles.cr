require "chronicle"
require "crig"

module Chronicle::Packs::Bundles
  # ActiveGraph Bundles — pre-assembled pack collections for common assistant
  # configurations. A bundle is a preset list of packs + default settings —
  # not a new pack. Ported from upstream `bundles/*` (revision
  # 6639a5385518ad49f74813373c85cf96eff9adc0).
  #
  # The bundle builders create a Runtime with the packs loaded and the owner
  # seeded. The port constructs the runtime over a memory store with a
  # deterministic mock completion model (the pack's LLM behaviors default to
  # the mock provider, so no API key is needed).

  # Deterministic mock completion model for bundle runtimes (mirrors the
  # spec-side ChatModel).
  class BundleModel
    include Crig::Completion::CompletionModel

    def completion(request : Crig::Completion::Request::CompletionRequest)
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.text(%({"reply": "Hello from the assistant bundle!"}))
        ),
        Crig::Completion::Usage.new(input_tokens: 1, output_tokens: 2),
        "raw",
        "msg_bundle",
      )
    end

    def stream(request : Crig::Completion::Request::CompletionRequest)
      raise "not implemented in test"
    end

    def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
      Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
    end
  end

  # A fresh store + graph + runtime (mirrors upstream `Runtime(Graph())`).
  def self.new_runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(BundleModel)}
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(BundleModel).new(model: BundleModel.new, preamble: "")
    la = Chronicle::LogAgent(BundleModel).new(agent, store: store, max_turns: 1)
    {store, graph, Chronicle::Runtime(BundleModel).new(store: store, log_agent: la, graph: graph)}
  end

  # Serialize an optional settings override to a JSON hash; nil means the
  # pack's own default settings apply.
  def self._settings_hash(override : JSON::Serializable?) : Hash(String, JSON::Any)?
    if override
      JSON.parse(override.to_json).as_h
    end
  end

  # The base assistant bundle pack list (upstream ASSISTANT_BUNDLE).
  ASSISTANT_BUNDLE = [
    Chronicle::Packs::Core.pack,
    Chronicle::Packs::ToolGateway.pack,
    Chronicle::Packs::Secrets.pack,
    Chronicle::Packs::MemoryGateway.pack,
    Chronicle::Packs::AgentProfile.pack,
    Chronicle::Packs::IdentityAuth.pack,
    Chronicle::Packs::Communication.pack,
    Chronicle::Packs::Schedule.pack,
    Chronicle::Packs::Chat.pack,
  ]

  # Alias for backward compatibility.
  ASSISTANT_PACK_LIST = ASSISTANT_BUNDLE

  # The messaging bundle: assistant + telegram + whatsapp.
  MESSAGING_BUNDLE = ASSISTANT_BUNDLE + [
    Chronicle::Packs::Telegram.pack,
    Chronicle::Packs::WhatsApp.pack,
  ]

  # The email bundle: assistant + email + entity.
  EMAIL_ASSISTANT_BUNDLE = ASSISTANT_BUNDLE + [
    Chronicle::Packs::Email.pack,
    Chronicle::Packs::Entity.pack,
  ]
  EMAIL_ASSISTANT_PACK_LIST = EMAIL_ASSISTANT_BUNDLE

  # The research bundle: core + tool_gateway + memory_gateway + communication
  # + chat + research (no identity/secrets — headless-friendly).
  RESEARCH_BUNDLE = [
    Chronicle::Packs::Core.pack,
    Chronicle::Packs::ToolGateway.pack,
    Chronicle::Packs::MemoryGateway.pack,
    Chronicle::Packs::Communication.pack,
    Chronicle::Packs::Chat.pack,
    Chronicle::Packs::Research.pack,
  ]
  RESEARCH_PACK_LIST = RESEARCH_BUNDLE

  # Register the Assistant Bundle packs onto an existing Runtime.
  def self.load_assistant_packs(rt : Chronicle::Runtime(M), *, core_settings : Chronicle::Packs::Core::CoreSettings? = nil, tool_gateway_settings : Chronicle::Packs::ToolGateway::ToolGatewaySettings? = nil, secrets_settings : Chronicle::Packs::Secrets::SecretsSettings? = nil, memory_gateway_settings : Chronicle::Packs::MemoryGateway::MemoryGatewaySettings? = nil, agent_profile_settings : Chronicle::Packs::AgentProfile::AgentProfileSettings? = nil, identity_settings : Chronicle::Packs::IdentityAuth::IdentitySettings? = nil, communication_settings : Chronicle::Packs::Communication::CommunicationSettings? = nil, schedule_settings : Chronicle::Packs::Schedule::ScheduleSettings? = nil, chat_settings : Chronicle::Packs::Chat::ChatSettings? = nil) : Chronicle::Runtime(M) forall M
    rt.load_pack(Chronicle::Packs::Core.pack, _settings_hash(core_settings))
    rt.load_pack(Chronicle::Packs::ToolGateway.pack, _settings_hash(tool_gateway_settings))
    rt.load_pack(Chronicle::Packs::Secrets.pack, _settings_hash(secrets_settings))
    rt.load_pack(Chronicle::Packs::MemoryGateway.pack, _settings_hash(memory_gateway_settings))
    rt.load_pack(Chronicle::Packs::AgentProfile.pack, _settings_hash(agent_profile_settings))
    rt.load_pack(Chronicle::Packs::IdentityAuth.pack, _settings_hash(identity_settings))
    rt.load_pack(Chronicle::Packs::Communication.pack, _settings_hash(communication_settings))
    rt.load_pack(Chronicle::Packs::Schedule.pack, _settings_hash(schedule_settings))
    settings = chat_settings || Chronicle::Packs::Chat::ChatSettings.new
    chat_pack = if settings.tool_allow_list.empty?
                  Chronicle::Packs::Chat.pack
                else
                  graph = rt.graph || raise Chronicle::Packs::PackError.new("bundle runtime has no graph")
                  proxies = Chronicle::Packs::ToolGateway.runtime_llm_tools_for(
                    graph,
                    settings.tool_allow_list,
                    tool_gateway_settings,
                  )
                  Chronicle::Packs::Chat.build_pack(proxies, settings.max_tool_turns)
                end
    rt.load_pack(chat_pack, _settings_hash(settings))
    rt
  end

  # Seed Principal objects for the configured owner identifiers.
  def self.seed_owner_principals(rt : Chronicle::Runtime(M), *, identity_settings : Chronicle::Packs::IdentityAuth::IdentitySettings? = nil) : Array(String) forall M
    settings = identity_settings || Chronicle::Packs::IdentityAuth::IdentitySettings.from_json("{}")
    return [] of String if settings.owner_identifiers.empty?
    graph = rt.graph || raise Chronicle::Packs::PackError.new("bundle runtime has no graph")
    ids = [] of String
    settings.owner_identifiers.each do |ref|
      out = Chronicle::Packs::IdentityAuth.register_principal_fn(graph, ref, "owner", channel: "any")
      ids << out.principal_id
    end
    rt.run_until_idle
    ids
  end

  # Seed a single default AgentProfile when none exists yet.
  def self.seed_default_profile(rt : Chronicle::Runtime(M), *, agent_profile_settings : Chronicle::Packs::AgentProfile::AgentProfileSettings? = nil) : String? forall M
    settings = agent_profile_settings || Chronicle::Packs::AgentProfile::AgentProfileSettings.from_json("{}")
    graph = rt.graph || raise Chronicle::Packs::PackError.new("bundle runtime has no graph")
    existing = begin
      graph.objects(type: "agent_profile")
    rescue
      return nil
    end
    return existing.first.id unless existing.empty?
    profile = Chronicle::Packs::AgentProfile.register_profile_fn(
      graph,
      name: settings.default_agent_name,
      mission: settings.default_mission,
      owner_name: settings.owner_name,
    )
    rt.run_until_idle
    profile.id
  end

  # Create a Runtime with the Assistant Bundle loaded.
  def self.build_assistant(
    *,
    core_settings : Chronicle::Packs::Core::CoreSettings? = nil,
    tool_gateway_settings : Chronicle::Packs::ToolGateway::ToolGatewaySettings? = nil,
    secrets_settings : Chronicle::Packs::Secrets::SecretsSettings? = nil,
    memory_gateway_settings : Chronicle::Packs::MemoryGateway::MemoryGatewaySettings? = nil,
    agent_profile_settings : Chronicle::Packs::AgentProfile::AgentProfileSettings? = nil,
    identity_settings : Chronicle::Packs::IdentityAuth::IdentitySettings? = nil,
    communication_settings : Chronicle::Packs::Communication::CommunicationSettings? = nil,
    schedule_settings : Chronicle::Packs::Schedule::ScheduleSettings? = nil,
    chat_settings : Chronicle::Packs::Chat::ChatSettings? = nil,
    seed_profile : Bool = true,
  ) : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(BundleModel)}
    Chronicle::Packs::IdentityAuth.clear_principal_registry
    store, graph, rt = new_runtime
    load_assistant_packs(
      rt,
      core_settings: core_settings,
      tool_gateway_settings: tool_gateway_settings,
      secrets_settings: secrets_settings,
      memory_gateway_settings: memory_gateway_settings,
      agent_profile_settings: agent_profile_settings,
      identity_settings: identity_settings,
      communication_settings: communication_settings,
      schedule_settings: schedule_settings,
      chat_settings: chat_settings,
    )
    if seed_profile
      seed_default_profile(rt, agent_profile_settings: agent_profile_settings)
    end
    seed_owner_principals(rt, identity_settings: identity_settings)
    {store, graph, rt}
  end

  # Register the Messaging Assistant Bundle packs onto an existing Runtime.
  def self.load_messaging_packs(rt : Chronicle::Runtime(M), *, telegram_settings : Chronicle::Packs::Telegram::TelegramSettings? = nil, whatsapp_settings : Chronicle::Packs::WhatsApp::WhatsAppSettings? = nil, **assistant_kwargs) : Chronicle::Runtime(M) forall M
    load_assistant_packs(rt, **assistant_kwargs)
    rt.load_pack(Chronicle::Packs::Telegram.pack, _settings_hash(telegram_settings))
    rt.load_pack(Chronicle::Packs::WhatsApp.pack, _settings_hash(whatsapp_settings))
    rt
  end

  # Create a Runtime with the Messaging Assistant Bundle loaded.
  def self.build_messaging_assistant(
    *,
    telegram_settings : Chronicle::Packs::Telegram::TelegramSettings? = nil,
    whatsapp_settings : Chronicle::Packs::WhatsApp::WhatsAppSettings? = nil,
    **assistant_kwargs,
  ) : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(BundleModel)}
    store, graph, rt = build_assistant(**assistant_kwargs)
    rt.load_pack(Chronicle::Packs::Telegram.pack, _settings_hash(telegram_settings))
    rt.load_pack(Chronicle::Packs::WhatsApp.pack, _settings_hash(whatsapp_settings))
    {store, graph, rt}
  end

  # Create a Runtime with the Email Assistant Bundle loaded.
  def self.build_email_assistant(
    *,
    core_settings : Chronicle::Packs::Core::CoreSettings? = nil,
    tool_gateway_settings : Chronicle::Packs::ToolGateway::ToolGatewaySettings? = nil,
    secrets_settings : Chronicle::Packs::Secrets::SecretsSettings? = nil,
    memory_gateway_settings : Chronicle::Packs::MemoryGateway::MemoryGatewaySettings? = nil,
    agent_profile_settings : Chronicle::Packs::AgentProfile::AgentProfileSettings? = nil,
    identity_settings : Chronicle::Packs::IdentityAuth::IdentitySettings? = nil,
    communication_settings : Chronicle::Packs::Communication::CommunicationSettings? = nil,
    chat_settings : Chronicle::Packs::Chat::ChatSettings? = nil,
    entity_settings : Chronicle::Packs::Entity::EntitySettings? = nil,
    email_settings : Chronicle::Packs::Email::EmailSettings? = nil,
  ) : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(BundleModel)}
    store, graph, rt = build_assistant(
      core_settings: core_settings,
      tool_gateway_settings: tool_gateway_settings,
      secrets_settings: secrets_settings,
      memory_gateway_settings: memory_gateway_settings,
      agent_profile_settings: agent_profile_settings,
      identity_settings: identity_settings,
      communication_settings: communication_settings,
      chat_settings: chat_settings,
    )
    rt.load_pack(Chronicle::Packs::Email.pack, _settings_hash(email_settings))
    entity = entity_settings || Chronicle::Packs::Entity::EntitySettings.from_json(%({"extract_from_raw_sources":true}))
    rt.load_pack(Chronicle::Packs::Entity.pack, _settings_hash(entity))
    {store, graph, rt}
  end

  # Create a Runtime with the Research Bundle loaded.
  def self.build_research_assistant(
    *,
    core_settings : Chronicle::Packs::Core::CoreSettings? = nil,
    tool_gateway_settings : Chronicle::Packs::ToolGateway::ToolGatewaySettings? = nil,
    memory_gateway_settings : Chronicle::Packs::MemoryGateway::MemoryGatewaySettings? = nil,
    communication_settings : Chronicle::Packs::Communication::CommunicationSettings? = nil,
    chat_settings : Chronicle::Packs::Chat::ChatSettings? = nil,
    research_settings : Chronicle::Packs::Research::ResearchSettings? = nil,
  ) : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(BundleModel)}
    store, graph, rt = new_runtime
    rt.load_pack(Chronicle::Packs::Core.pack, _settings_hash(core_settings))
    rt.load_pack(Chronicle::Packs::ToolGateway.pack, _settings_hash(tool_gateway_settings))
    rt.load_pack(Chronicle::Packs::MemoryGateway.pack, _settings_hash(memory_gateway_settings))
    rt.load_pack(Chronicle::Packs::Communication.pack, _settings_hash(communication_settings))
    rt.load_pack(Chronicle::Packs::Chat.pack, _settings_hash(chat_settings))
    rt.load_pack(Chronicle::Packs::Research.pack, _settings_hash(research_settings))
    {store, graph, rt}
  end
end
