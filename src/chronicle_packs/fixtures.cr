require "chronicle"
require "crig"
require "json"
require "file_utils"

module Chronicle::Packs::Fixtures
  # Cross-pack integration fixtures (upstream packs/fixtures/*). Each
  # scenario builds a runtime with its packs loaded, drives the full
  # graph-driven flow, and asserts the integration shape — all in-process,
  # no LLM, no API key (the deterministic driver pattern established by the
  # per-pack fixtures; upstream runs these as subprocess scripts).
  #
  # Divergences (see plans/parity.md):
  # - The `main` CLIs are driven in-process by specs; there is no
  #   subprocess runner (upstream `run_all.py` shells out per fixture).
  # - `chat_memory_cross_session` persists the event log to a SQLite event
  #   store file and replays it into a fresh graph for session 2 (the
  #   port's memory gateway is graph-backed; upstream uses a separate
  #   SQLite memory backend file). Recall still crosses the session
  #   boundary.
  # - The upstream `run_all` fixture list only names the first three
  #   scenarios; the port runs all five in-process so the exit code
  #   reflects the whole suite.

  # The checkout root (upstream run_all.REPO_ROOT).
  REPO_ROOT = Path[__DIR__].parent.parent

  # The fixture scenarios (label → scenario). In-process drivers, not
  # subprocess scripts.
  FIXTURES = [
    {"Tool Gateway → Core → Memory Gateway", :cross_pack_integration},
    {"Communication + Chat + Email + Identity + Core", :comm_chat_email_integration},
    {"Identity/Auth + Agent Profile + Entity + Core", :identity_profile_entity_integration},
    {"Cross-session long-term memory (chat)", :chat_memory_cross_session},
    {"L2 Habit closed-loop (skills + memory + usage)", :l2_habit_integration},
  ]

  # Deterministic mock completion model for fixture runtimes (mirrors the
  # spec-side ChatModel / bundle BundleModel). LLM behaviors consume it.
  class FixtureModel
    include Crig::Completion::CompletionModel

    @calls = 0

    def completion(request : Crig::Completion::Request::CompletionRequest)
      @calls += 1
      Crig::Completion::CompletionResponse(String).new(
        Crig::OneOrMany(Crig::Completion::AssistantContent).one(
          Crig::Completion::AssistantContent.text(%({"reply": "Here is a response for you."}))
        ),
        Crig::Completion::Usage.new(input_tokens: 1, output_tokens: 2),
        "raw",
        "msg_fixture_#{@calls}",
      )
    end

    def stream(request : Crig::Completion::Request::CompletionRequest)
      raise "not implemented in test"
    end

    def completion_request(prompt : Crig::Completion::Message | String) : Crig::Completion::Request::CompletionRequestBuilder
      Crig::Completion::Request::CompletionRequestBuilder.new(prompt)
    end
  end

  # ---- runtime builder ---------------------------------------------------

  # A fresh store + graph + runtime (mirrors upstream `Runtime(Graph())`).
  def self._new_runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(FixtureModel)}
    store = Chronicle::MemoryEventStore.new
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    agent = Crig::Agent(FixtureModel).new(model: FixtureModel.new, preamble: "")
    la = Chronicle::LogAgent(FixtureModel).new(agent, store: store, max_turns: 1)
    {store, graph, Chronicle::Runtime(FixtureModel).new(store: store, log_agent: la, graph: graph)}
  end

  def self._settings_hash(override : JSON::Serializable?) : Hash(String, JSON::Any)?
    if override
      JSON.parse(override.to_json).as_h
    end
  end

  # ---------------------------------------------------------------- runner

  # Run every fixture in-process. Returns the exit code (0 = all pass).
  def self.main(argv : Array(String)? = nil, io : IO = STDOUT) : Int32
    io.puts
    io.puts("=" * 65)
    io.puts("Cross-Pack Integration Fixtures")
    io.puts("=" * 65)
    io.puts

    results = [] of Bool
    FIXTURES.each_with_index do |(label, scenario), index|
      io.puts("[#{index + 1}] #{label}")
      passed = _run_fixture(scenario)
      results << passed
      io.puts("  #{passed ? "PASS" : "FAIL"}  #{label}")
      io.puts
    end

    io.puts("=" * 65)
    passed_count = results.count(&.itself)
    failed = results.size - passed_count
    if failed == 0
      io.puts("ALL PASSED (#{passed_count}/#{results.size})")
      io.puts("=" * 65)
      0
    else
      io.puts("FAILED #{failed}/#{results.size} fixture(s)")
      io.puts("=" * 65)
      1
    end
  end

  def self._run_fixture(scenario : Symbol) : Bool
    case scenario
    when :cross_pack_integration
      run_cross_pack_integration
    when :comm_chat_email_integration
      run_all_comm_chat_email
    when :identity_profile_entity_integration
      run_all_identity_profile_entity
    when :chat_memory_cross_session
      result = run_cross_session_memory
      result["contexts"].as_i >= 1 && result["recalled_items"].as_i >= 1
    when :l2_habit_integration
      result = run_l2_habit_fixture
      result["skill_used_events"].as_i == 1
    else
      false
    end
  end

  # -------------------------------------------------- cross_pack_integration

  # Tool Gateway → Core → Memory Gateway, fully graph-driven.
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of the upstream scenario
  def self.run_cross_pack_integration : Bool
    _store, graph, rt = _new_runtime

    rt.load_pack(Chronicle::Packs::Core.pack, _settings_hash(
      Chronicle::Packs::Core::CoreSettings.from_json(%({"observation_min_confidence":0.3,"max_observations_per_source":8}))
    ))
    rt.load_pack(Chronicle::Packs::ToolGateway.pack, _settings_hash(
      Chronicle::Packs::ToolGateway::ToolGatewaySettings.new(
        auto_approve_risk_classes: ["low", "medium"],
        create_source_from_result: true,
        record_output_data: true,
      )
    ))
    rt.load_pack(Chronicle::Packs::Secrets.pack)
    rt.load_pack(Chronicle::Packs::MemoryGateway.pack, _settings_hash(
      Chronicle::Packs::MemoryGateway::MemoryGatewaySettings.new(
        acceptance_threshold: 0.5,
        auto_accept_categories: ["preference", "instruction", "decision", "fact"],
      )
    ))

    Chronicle::Packs::ToolGateway.credential_resolver = ->(g : Chronicle::GraphProjection, name : String, ref_id : String?) {
      Chronicle::Packs::Secrets.resolve_and_audit_fn(
        g, name,
        behavior_name: "integration_test",
        frame_id: "frame_integration_001",
        credential_ref_id: ref_id,
      )
    }

    Chronicle::Packs::ToolGateway.register_local_capability(
      "crm", "lookup_company",
      ->(input : Hash(String, JSON::Any)) {
        {"company"        => JSON::Any.new(input["company_name"]?.try(&.as_s?) || ""),
         "founded"        => JSON::Any.new(2021),
         "arr"            => JSON::Any.new("$2.4M"),
         "headcount"      => JSON::Any.new(18),
         "key_preference" => JSON::Any.new("API-first architecture preferred."),
         "decision"       => JSON::Any.new("Team decided to adopt event sourcing."),
         "instruction"    => JSON::Any.new("Always use JSON for API responses.")}
      },
      risk_class: "low",
      action_class: "R0",
    )

    provider = graph.add_object("capability_provider", JSON.build do |json|
      json.object do
        json.field "name", "crm"
        json.field "kind", "api"
        json.field "base_url", "https://crm.example.com"
        json.field "description", "Mock CRM for integration test"
        json.field "capabilities", JSON::Any.new(["lookup_company"].map { |cap| JSON::Any.new(cap) })
        json.field "credential_ref_name", "CRM_API_KEY"
        json.field "enabled", true
        json.field "metadata", JSON::Any.new({} of String => JSON::Any)
      end
    end)
    cred_ref = graph.add_object("credential_ref", JSON.build do |json|
      json.object do
        json.field "name", "CRM_API_KEY"
        json.field "scope", "read"
        json.field "provider_hint", "crm"
        json.field "last_used_at", JSON::Any.new(nil)
        json.field "use_count", 0
        json.field "enabled", true
        json.field "metadata", JSON::Any.new({} of String => JSON::Any)
      end
    end)
    rt.run_until_idle

    Chronicle::Packs::Secrets.resolve_and_audit_fn(
      graph,
      "CRM_API_KEY",
      behavior_name: "integration_test",
      frame_id: "frame_integration_001",
      credential_ref_id: cred_ref.id,
    )
    rt.run_until_idle

    call = graph.add_object("capability_call", JSON.build do |json|
      json.object do
        json.field "provider_id", provider.id
        json.field "provider_name", "crm"
        json.field "capability_name", "lookup_company"
        json.field "input_data", JSON.parse(%({"company_name":"Northwind Robotics"}))
        json.field "credential_ref_name", "CRM_API_KEY"
        json.field "credential_ref_id", cred_ref.id
        json.field "risk_class", "low"
        json.field "status", "proposed"
        json.field "proposed_by", "integration_test"
        json.field "frame_id", "frame_integration_001"
        json.field "proposed_at", "2026-06-03T10:00:00Z"
        json.field "metadata", JSON::Any.new({} of String => JSON::Any)
      end
    end)
    rt.run_until_idle

    call_obj = graph.get_object(call.id)
    call_status = call_obj.try { |obj| JSON.parse(obj.data)["status"]?.try(&.as_s?) }
    approvals = graph.objects(type: "capability_approval")
    results = graph.objects(type: "capability_result")
    cred_after_call = graph.get_object(cred_ref.id)
    cred_use_count = cred_after_call.try { |obj| JSON.parse(obj.data)["use_count"]?.try(&.as_i?) } || 0

    sources = graph.objects(type: "source")
    observations = graph.objects(type: "observation")
    evaluations = graph.objects(type: "evaluation")
    memory_items = graph.objects(type: "memory_item")

    _request = graph.add_object("memory_retrieval_request", JSON.build do |json|
      json.object do
        json.field "query", "API architecture preferences JSON"
        json.field "top_k", 5
        json.field "min_score", 0.1
        json.field "category", JSON::Any.new(nil)
        json.field "behavior_name", "integration_test"
        json.field "frame_id", "frame_integration_001"
        json.field "backend_url", ":memory:"
        json.field "metadata", JSON::Any.new({} of String => JSON::Any)
      end
    end)
    rt.run_until_idle

    retrievals = graph.objects(type: "memory_retrieval")
    _rankings = graph.objects(type: "memory_ranking")

    failures = [] of String
    failures << "no capability_approval — policy_enforcer did not create approval" if approvals.empty?
    failures << "no capability_result — call_executor behavior did not fire" if results.empty?
    failures << "expected call status 'done', got '#{call_status}'" if call_status != "done"
    failures << "no sources — result_sourcer did not fire" if sources.empty?
    failures << "no observations — Core observation_extractor did not fire" if observations.empty?
    failures << "no evaluations — Memory Gateway candidate_evaluator did not fire" if evaluations.empty?
    failures << "no memory_retrieval — memory_retriever behavior did not fire" if retrievals.empty?
    failures << "call_executor did not inject credentials (use_count=#{cred_use_count})" if cred_use_count < 2

    expected_relations = ["calls", "approved_by", "produces_result", "sourced_as", "evaluates", "fulfilled_by"]
    present_relations = graph.relations.map(&.type).to_set
    expected_relations.each do |rel|
      failures << "missing relation type '#{rel}'" unless present_relations.includes?(rel)
    end

    if results.empty?
      failures << "capability_result missing 'sanitized' field — sanitizer not wired"
    else
      result_output = JSON.parse(results.first.data)["output_data"]?.try(&.as_s?) || ""
      failures << "capability_result.output_data contains unsanitized secret patterns" if result_output.includes?("sk-") || result_output.includes?("AKIA")
    end
    failures << "no memory items were accepted" if memory_items.empty?

    Chronicle::Packs::ToolGateway.clear_local_registry
    failures.empty?
  end

  # ----------------------------------------- comm_chat_email_integration

  def self.run_full_comm_stack_integration : Hash(String, JSON::Any)
    g, rt = _make_full_runtime

    Chronicle::Packs::Email.ingest_email_fn(
      g,
      message_id: "<founder-001@mail.sequoia.com>",
      from_addr: "sarah.thompson@sequoia.com",
      to_addrs: ["alice@northwind.ai"],
      subject: "Investment interest in Northwind AI",
      body_text: "Hi Alice,\n\nWe'd love to schedule a call to discuss a potential seed investment in Northwind AI. Could you please share your latest deck and financials?\n\nBest,\nSarah Thompson\nSequoia Capital",
      received_at: "2026-06-03T09:00:00Z",
    )
    rt.run_until_idle

    sources = g.objects(type: "source")
    comm_msgs = g.objects(type: "comm_message")
    email_threads = g.objects(type: "email_thread")
    comm_threads = g.objects(type: "comm_thread")
    _principals = g.objects(type: "principal")
    intents = g.objects(type: "comm_intent")

    comm_msg_id = comm_msgs.first.id

    Chronicle::Packs::Email.create_email_response_fn(
      g,
      comm_message_id: comm_msg_id,
      content: "Hi Sarah,\n\nThank you for your interest in Northwind AI! I'd be happy to schedule a call. I'll send over our latest deck and financials shortly.\n\nBest regards,\nAlice",
    )
    rt.run_until_idle

    email_drafts = g.objects(type: "email_draft")
    actions = g.objects(type: "action")
    approval_actions = actions.select { |action| JSON.parse(action.data)["kind"]?.try(&.as_s?) == "approval_request" }

    Chronicle::Packs::Chat.submit_chat_input_fn(
      g,
      user_ref: "alice@northwind.ai",
      content: "What should I highlight in my reply to Sarah at Sequoia?",
    )
    rt.run_until_idle

    chat_sessions = g.objects(type: "chat_session")
    chat_turns = g.objects(type: "chat_turn")

    Chronicle::Packs::Email.ingest_email_fn(
      g,
      message_id: "<founder-002@mail.sequoia.com>",
      from_addr: "sarah.thompson@sequoia.com",
      to_addrs: ["alice@northwind.ai"],
      subject: "Re: Investment interest in Northwind AI",
      body_text: "Alice, thanks for the quick reply! Looking forward to connecting.",
      in_reply_to: "<founder-001@mail.sequoia.com>",
      thread_id: "<founder-001@mail.sequoia.com>",
      received_at: "2026-06-03T10:00:00Z",
    )
    rt.run_until_idle

    email_threads_final = g.objects(type: "email_thread")
    thread_data = email_threads_final.first.try { |obj| JSON.parse(obj.data) }
    all_principals = g.objects(type: "principal")
    owner_principals = all_principals.select { |principal| JSON.parse(principal.data)["role"]?.try(&.as_s?) == "owner" }
    external_principals = all_principals.select { |principal| JSON.parse(principal.data)["role"]?.try(&.as_s?) == "external" }

    {
      "sources"                          => JSON::Any.new(sources.size),
      "comm_messages"                    => JSON::Any.new(comm_msgs.size),
      "comm_threads"                     => JSON::Any.new(comm_threads.size),
      "email_threads"                    => JSON::Any.new(email_threads.size),
      "principals"                       => JSON::Any.new(all_principals.size),
      "owner_principals"                 => JSON::Any.new(owner_principals.size),
      "external_principals"              => JSON::Any.new(external_principals.size),
      "intents"                          => JSON::Any.new(intents.map { |i| JSON::Any.new(JSON.parse(i.data)["intent"]?.try(&.as_s?) || "") }),
      "email_drafts"                     => JSON::Any.new(email_drafts.size),
      "approval_actions"                 => JSON::Any.new(approval_actions.size),
      "chat_sessions"                    => JSON::Any.new(chat_sessions.size),
      "chat_turns"                       => JSON::Any.new(chat_turns.size),
      "chat_assistant_message_populated" => JSON::Any.new(!chat_turns.empty? && !(JSON.parse(chat_turns.first.data)["assistant_message"]?.try(&.raw.nil?))),
      "email_thread_message_count"       => JSON::Any.new(thread_data.try { |data| data["message_count"]?.try(&.as_i?) } || 0),
      "relation_types"                   => JSON::Any.new(g.relations.map(&.type).uniq!.sort!.map { |rel| JSON::Any.new(rel) }),
    }
  end

  def self._make_full_runtime : {Chronicle::GraphProjection, Chronicle::Runtime(FixtureModel)}
    Chronicle::Packs::IdentityAuth.clear_principal_registry
    Chronicle::Packs::Communication.clear_thread_registry
    Chronicle::Packs::Chat.clear_session_registry
    Chronicle::Packs::Email.clear_email_registry

    _store, graph, rt = _new_runtime
    rt.load_pack(Chronicle::Packs::Core.pack)
    rt.load_pack(Chronicle::Packs::IdentityAuth.pack, _settings_hash(
      Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(
        %({"owner_identifiers":["alice@northwind.ai"],"default_external_role":"external"})
      )
    ))
    rt.load_pack(Chronicle::Packs::Communication.pack)
    rt.load_pack(Chronicle::Packs::Email.pack, _settings_hash(
      Chronicle::Packs::Email::EmailSettings.new(
        owner_email_addresses: ["alice@northwind.ai"],
        require_approval_for_external: true,
      )
    ))
    rt.load_pack(Chronicle::Packs::Chat.pack, _settings_hash(
      Chronicle::Packs::Chat::ChatSettings.new(
        llm_provider: "mock",
        auto_approve_responses: true,
      )
    ))
    {graph, rt}
  end

  def self.run_all_comm_chat_email : Bool
    result = run_full_comm_stack_integration
    result["sources"].as_i == 1 &&
      result["comm_messages"].as_i == 1 &&
      result["email_threads"].as_i == 1 &&
      result["owner_principals"].as_i >= 1 &&
      result["external_principals"].as_i >= 1 &&
      result["email_drafts"].as_i == 1 &&
      result["approval_actions"].as_i >= 1 &&
      result["chat_sessions"].as_i == 1 &&
      result["chat_assistant_message_populated"].as_bool
  end

  # -------------------------------------- identity_profile_entity_integration

  def self.run_identity_profile_entity_composition : Bool
    Chronicle::Packs::IdentityAuth.clear_principal_registry
    Chronicle::Packs::AgentProfile.clear_profile_registry
    Chronicle::Packs::Entity.clear_entity_registry

    _store, graph, rt = _new_runtime
    rt.load_pack(Chronicle::Packs::Core.pack)
    rt.load_pack(Chronicle::Packs::IdentityAuth.pack, _settings_hash(
      Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(
        %({"owner_identifiers":["alice@example.com"],"default_external_role":"external","owner_auth_confidence":0.95,"create_auth_context":true,"check_permissions_on_proposed_actions":true})
      )
    ))
    rt.load_pack(Chronicle::Packs::AgentProfile.pack, _settings_hash(
      Chronicle::Packs::AgentProfile::AgentProfileSettings.from_json(
        %({"owner_name":"Alice","expose_mission_to_external":false,"default_tone":"direct"})
      )
    ))
    rt.load_pack(Chronicle::Packs::Entity.pack, _settings_hash(
      Chronicle::Packs::Entity::EntitySettings.from_json(
        %({"extraction_min_confidence":0.6,"resolution_similarity_threshold":0.75,"auto_accept_exact_identifier_match":true,"extract_from_raw_sources":true})
      )
    ))

    profile = Chronicle::Packs::AgentProfile.register_profile_fn(
      graph,
      name: "Aria",
      mission: "Help Alice build Northwind Robotics into a category-defining company.",
      personality_description: "Direct, analytical, candid. Respects Alice's time.",
      owner_name: "Alice",
    )
    graph.add_object("standing_instruction", JSON.build do |json|
      json.object do
        json.field "text", "For Alice: lead with the answer, then the reasoning."
        json.field "scope", "communication"
        json.field "applies_to_channel", "email"
        json.field "applies_to_audience_role", "owner"
        json.field "priority", 90
        json.field "active", true
        json.field "profile_id", profile.id
        json.field "metadata", JSON::Any.new({} of String => JSON::Any)
      end
    end)
    graph.add_object("goal", JSON.build do |json|
      json.object do
        json.field "text", "Close a $3M seed round by Q3 2026."
        json.field "priority", "critical"
        json.field "status", "active"
        json.field "domain", "fundraising"
        json.field "profile_id", profile.id
        json.field "metadata", JSON::Any.new({} of String => JSON::Any)
      end
    end)
    rt.run_until_idle

    graph.add_object("source", JSON.build do |json|
      json.object do
        json.field "kind", "email"
        json.field "content", "Hi, just got off a call with Sarah Thompson from Sequoia Capital. She's interested in Northwind Robotics and wants a deck. Her email is sarah.thompson@sequoia.com. Let's follow up on the seed round — can you draft a first email to her?"
        json.field "sender_ref", "alice@example.com"
        json.field "channel", "email"
        json.field "frame_id", "frame_incoming_001"
        json.field "metadata", JSON::Any.new({} of String => JSON::Any)
      end
    end)
    rt.run_until_idle

    principals = graph.objects(type: "principal")
    auth_contexts = graph.objects(type: "auth_context")
    entity_mentions = graph.objects(type: "entity_mention")
    entities = graph.objects(type: "entity")
    owner_principals = principals.select { |principal| JSON.parse(principal.data)["role"]?.try(&.as_s?) == "owner" }

    Chronicle::Packs::AgentProfile.request_profile_context_fn(
      graph,
      profile_id: profile.id,
      channel: "email",
      audience_role: "owner",
      frame_id: "frame_incoming_001",
    )
    rt.run_until_idle

    context_views = graph.objects(type: "profile_context_view").select { |view| JSON.parse(view.data)["audience_role"]?.try(&.as_s?) == "owner" }

    failures = [] of String
    failures << "principal_resolver: no owner principal created" if owner_principals.empty?
    failures << "auth_context_builder: no auth_context created" if auth_contexts.empty?
    failures << "entity_extractor: no entity_mentions extracted from email" if entity_mentions.empty?
    failures << "entity_resolver: no entities created" if entities.empty?
    if context_views.empty?
      failures << "profile_context_provider: no context view assembled"
    else
      cv = JSON.parse(context_views.first.data)
      failures << "Owner-facing context missing mission" if cv["mission"]?.try(&.as_s?).nil? || cv["mission"].as_s.empty?
      failures << "Context view missing active goals" if (cv["active_goals"]?.try(&.as_a?) || [] of JSON::Any).empty?
    end

    present_relations = graph.relations.map(&.type).to_set
    {"resolves_to", "authenticated_by", "refers_to", "fulfilled_by_profile"}.each do |rel|
      failures << "Missing relation: #{rel}" unless present_relations.includes?(rel)
    end

    failures.empty?
  end

  def self.run_all_identity_profile_entity : Bool
    run_identity_profile_entity_composition
  end

  # ------------------------------------------------- chat_memory_cross_session

  STORED_PREFERENCE = "I always prefer dark mode and concise answers."
  RETURNING_QUERY   = "What are my dark mode preferences?"

  # Reset all module-level dedup registries (upstream `_clear_registries`).
  def self._clear_registries : Nil
    Chronicle::Packs::Chat.clear_session_registry
    Chronicle::Packs::IdentityAuth.clear_principal_registry
    Chronicle::Packs::Communication.clear_thread_registry
  end

  # Build an assistant runtime whose event log persists to *mem_path*.
  # The port's memory is graph-backed, so cross-session persistence is the
  # event log replay (chronicle's SQLite event store).
  def self._build_session(mem_path : String, run_id : String, agent : Crig::Agent(FixtureModel)) : {Chronicle::SQLiteEventStore, Chronicle::GraphProjection, Chronicle::Runtime(FixtureModel)}
    store = Chronicle::SQLiteEventStore.new(mem_path, run_id)
    graph = Chronicle::GraphProjection.empty.attach_store(store)
    la = Chronicle::LogAgent(FixtureModel).new(agent, store: store, max_turns: 1)
    rt = Chronicle::Runtime(FixtureModel).new(store: store, log_agent: la, graph: graph, run_id: run_id)
    Chronicle::Packs::Bundles.load_assistant_packs(
      rt,
      memory_gateway_settings: Chronicle::Packs::MemoryGateway::MemoryGatewaySettings.new(backend_url: mem_path),
      chat_settings: Chronicle::Packs::Chat::ChatSettings.new(memory_backend_url: mem_path),
    )
    {store, graph, rt}
  end

  # Write a preference in session 1, recall it in a fresh session 2.
  def self.run_cross_session_memory : Hash(String, JSON::Any)
    _clear_all_backends
    _clear_registries

    tmpdir = Path.new(Dir.tempdir) / "ag_xsession_mem_#{Random::Secure.hex(4)}"
    FileUtils.mkdir_p(tmpdir.to_s)
    mem_path = (tmpdir / "memory.sqlite").to_s

    agent = Crig::Agent(FixtureModel).new(model: FixtureModel.new, preamble: "")
    run_id = "session1"

    # ── Session 1: state a durable preference ──────────────────────────────
    _store1, _graph1, rt1 = _build_session(mem_path, run_id, agent)
    graph1 = rt1.graph || raise Chronicle::Packs::PackError.new("fixture runtime has no graph")
    Chronicle::Packs::Bundles.seed_owner_principals(rt1, identity_settings: Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(%({"owner_identifiers":["alice"]})))
    Chronicle::Packs::Chat.submit_chat_input_fn(graph1, user_ref: "alice", content: STORED_PREFERENCE)
    rt1.run_until_idle
    stored_count = graph1.objects(type: "memory_item").size

    # ── Simulate a restart: close the connection (keep the file), drop registries.
    _store1.close
    _clear_registries

    # ── Session 2: replay the persisted event log into a FRESH graph ───────
    # (the port's memory is graph-backed, so cross-session persistence is the
    #  event-log replay — upstream uses a separate SQLite memory backend file)
    rt2 = Chronicle::Runtime(FixtureModel).load(mem_path, run_id, agent)
    Chronicle::Packs::Bundles.load_assistant_packs(
      rt2,
      memory_gateway_settings: Chronicle::Packs::MemoryGateway::MemoryGatewaySettings.new(backend_url: mem_path),
      chat_settings: Chronicle::Packs::Chat::ChatSettings.new(memory_backend_url: mem_path),
    )
    Chronicle::Packs::Bundles.seed_owner_principals(rt2, identity_settings: Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(%({"owner_identifiers":["alice"]})))
    graph2 = rt2.graph || raise Chronicle::Packs::PackError.new("fixture runtime has no graph")

    Chronicle::Packs::Chat.submit_chat_input_fn(graph2, user_ref: "alice", content: RETURNING_QUERY)
    rt2.run_until_idle

    contexts = graph2.objects(type: "memory_context")
    summaries = contexts.map { |ctx| JSON.parse(ctx.data)["summary"]?.try(&.as_s?) || "" }
    recalled = summaries.any?(&.downcase.includes?("dark mode"))
    total_recalled = contexts.sum { |ctx| JSON.parse(ctx.data)["item_count"]?.try(&.as_i?) || 0 }

    FileUtils.rm_rf(tmpdir)

    {
      "stored_count"   => JSON::Any.new(stored_count),
      "contexts"       => JSON::Any.new(contexts.size),
      "recalled_items" => JSON::Any.new(total_recalled),
      "summaries"      => JSON::Any.new(summaries.map { |summary| JSON::Any.new(summary) }),
      "recalled"       => JSON::Any.new(recalled),
    }
  end

  # ------------------------------------------------- l2_habit_integration

  def self.run_l2_habit_fixture : Hash(String, JSON::Any)
    _store, _graph, rt = _l2_runtime
    graph = rt.graph || raise Chronicle::Packs::PackError.new("fixture runtime has no graph")

    Chronicle::Packs::Usage.connect_surface_fn(
      graph,
      "surface_l2_habit",
      "code_work",
      provider: {"name" => JSON::Any.new("constitution_dogfood")},
      path: "local",
      acquisition_mode: "snapshot",
      is_fixture: false,
    )
    _acquire_skill_candidate(graph)
    rt.run_until_idle

    skills = graph.objects(type: "skill")
    skill = skills.first
    skill_data = JSON.parse(skill.data)

    _first = Chronicle::Packs::Skills.invoke_skill_fn(
      graph,
      skill_data["name"].as_s,
      skill_data["version"].as_s,
      "habit-usage-1",
      "trial:habit-loop:1",
      execution_kind: "trial",
      actor: "agent:habit-fixture",
      source_context: {
        "source_surface_id" => JSON::Any.new("surface_l2_habit"),
        "source_category"   => JSON::Any.new("code_work"),
        "provider_time"     => JSON::Any.new("2026-07-09T09:00:00Z"),
      },
      is_fixture: false,
    )
    _retry = Chronicle::Packs::Skills.invoke_skill_fn(
      graph,
      skill_data["name"].as_s,
      skill_data["version"].as_s,
      "habit-usage-1",
      "trial:habit-loop:1",
      execution_kind: "trial",
      actor: "agent:habit-fixture",
      source_context: {
        "source_surface_id" => JSON::Any.new("surface_l2_habit"),
        "source_category"   => JSON::Any.new("code_work"),
        "provider_time"     => JSON::Any.new("2026-07-09T09:00:00Z"),
      },
      is_fixture: false,
    )

    verdict = Chronicle::Packs::EvalOutcome.record_explicit_verdict_fn(
      graph,
      "accept",
      "the digest helped the owner close the review",
      "owner:habit-fixture",
      usage_id: "habit-usage-1",
      source_context: {
        "source_surface_id" => JSON::Any.new("surface_l2_habit"),
        "source_category"   => JSON::Any.new("outcome_evaluation"),
      },
      is_fixture: false,
    )
    rt.run_until_idle

    Chronicle::Packs::Usage.record_usage_fn(
      graph,
      "habit-interaction-2026-07-09",
      "surface_l2_habit",
      "skill_interaction",
      provider_time: "2026-07-09T09:00:00Z",
      is_fixture: false,
      provenance: {"skill_usage_id" => JSON::Any.new("habit-usage-1")},
    )
    Chronicle::Packs::Usage.record_usage_fn(
      graph,
      "habit-interaction-2026-07-10",
      "surface_l2_habit",
      "owner_verdict",
      provider_time: "2026-07-10T09:00:00Z",
      is_fixture: false,
      provenance: {"evaluation_id" => JSON::Any.new(verdict["evaluation_id"].as_s)},
    )

    memory = _memory_reliability_scenario(rt)

    skill_used = graph.events.select { |event| event.type == "skill.used" && !(JSON.parse(event.payload)["is_fixture"]?.try(&.as_bool?) || false) }
    skill_terminals = graph.events.select { |event| event.type.in?({"outcome.helped", "outcome.hurt", "outcome.neutral"}) && (JSON.parse(event.payload)["evaluation_id"]?.try(&.as_s?) == verdict["evaluation_id"].as_s) }
    interaction_dates = graph.events.select { |event| event.type == "usage.recorded" && !(JSON.parse(event.payload)["is_fixture"]?.try(&.as_bool?) || false) && (JSON.parse(event.payload)["provider_time"]?.try(&.as_s?)) }.map { |event| _date_of(JSON.parse(event.payload)["provider_time"].as_s) }.uniq!.sort!

    {
      "skill_version_id"      => JSON::Any.new(skill.id),
      "skill_usage_id"        => JSON::Any.new("habit-usage-1"),
      "skill_used_events"     => JSON::Any.new(skill_used.size),
      "terminal_outcome"      => JSON::Any.new(skill_terminals.first.type),
      "interaction_utc_dates" => JSON::Any.new(interaction_dates.map { |date| JSON::Any.new(date) }),
      "memory"                => JSON::Any.new(memory),
    }
  end

  def self._l2_runtime : {Chronicle::MemoryEventStore, Chronicle::GraphProjection, Chronicle::Runtime(FixtureModel)}
    _clear_all_backends
    store, graph, rt = _new_runtime
    rt.load_pack(Chronicle::Packs::Core.pack)
    # The upstream fixture runs the annotation-first shared-extraction layer
    # (semantic_extraction) to mint the skill_candidate. The port's
    # semantic_extraction default facets only cover `communication` (the
    # zero-key `semantic.deterministic` extractor), so a `code_work` skill
    # candidate is minted via the activity_normalizer legacy direct-write
    # path instead (the deterministic StructureExtractor's SKILL_RE), which
    # is the port's ADR 0026 rollback seam. Same skill object, same
    # lifecycle.
    rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack, _settings_hash(
      Chronicle::Packs::ActivityNormalizer::ActivityNormalizerSettings.new(legacy_extraction_enabled: true)
    ))
    rt.load_pack(Chronicle::Packs::Usage.pack)
    rt.load_pack(Chronicle::Packs::Skills.pack)
    rt.load_pack(Chronicle::Packs::MemoryGateway.pack, _settings_hash(
      Chronicle::Packs::MemoryGateway::MemoryGatewaySettings.new(backend_url: ":memory:")
    ))
    rt.load_pack(Chronicle::Packs::EvalOutcome.pack)
    {store, graph, rt}
  end

  def self._acquire_skill_candidate(graph : Chronicle::GraphProjection) : Nil
    payload = "Skill: daily_repo_digest"
    digest = Digest::SHA256.hexdigest(payload)
    item = graph.add_object("acquired_item", JSON.build do |json|
      json.object do
        json.field "source_surface_id", "surface_l2_habit"
        json.field "provider_item_id", "habit-skill-definition-1"
        json.field "dedup_key", "habit-skill-definition-1"
        json.field "source_ref", "dogfood://habit/skill-definition-1"
        json.field "source_hash", digest
        json.field "provider_time", "2026-07-09T08:00:00Z"
        json.field "replay_mode", "inline"
        json.field "replay_payload_ref", payload
        json.field "replay_payload_hash", digest
        json.field "media_type", "text/plain"
        json.field "importer_id", "l2_habit_fixture"
        json.field "importer_version", "0.1.0"
      end
    end)
    graph.add_object("acquired_content", JSON.build do |json|
      json.object do
        json.field "acquired_item_id", item.id
        json.field "normalized_content", payload
        json.field "normalized_metadata", JSON::Any.new({} of String => JSON::Any)
        json.field "source_category", "code_work"
        json.field "connection_path", "local"
        json.field "is_fixture", false
      end
    end)
    nil
  end

  def self._memory_reliability_scenario(rt : Chronicle::Runtime(FixtureModel)) : Hash(String, JSON::Any)
    graph = rt.graph || raise Chronicle::Packs::PackError.new("fixture runtime has no graph")
    existing_ids = graph.objects(type: "memory_item").map(&.id).to_set
    ["Habit review happens every Friday.", "Habit review happens every Friday with the owner."].each do |text|
      graph.add_object("memory_candidate", JSON.build do |json|
        json.object do
          json.field "text", text
          json.field "confidence", 0.95
          json.field "source_ids", JSON::Any.new([] of JSON::Any)
          json.field "observation_ids", JSON::Any.new([] of JSON::Any)
          json.field "category", "fact"
          json.field "accepted", false
        end
      end)
    end
    rt.run_until_idle

    created = graph.objects(type: "memory_item").select { |item| !existing_ids.includes?(item.id) }
    target = created.first
    Chronicle::Packs::EvalOutcome.record_explicit_verdict_fn(
      graph,
      "reject",
      "the memory caused a verified wrong reminder",
      "owner:habit-fixture",
      artifact_id: target.id,
      artifact_type: "memory_item",
    )
    rt.run_until_idle

    demoted = Chronicle::Packs::MemoryGateway.retrieve_memories_fn(graph, "habit review Friday", min_score: 0.0).find! { |row| row["item_id"].as_s == target.id }
    Chronicle::Packs::EvalOutcome.record_explicit_verdict_fn(
      graph,
      "accept",
      "later evidence verified the memory",
      "owner:habit-fixture",
      artifact_id: target.id,
      artifact_type: "memory_item",
    )
    rt.run_until_idle
    restored = Chronicle::Packs::MemoryGateway.retrieve_memories_fn(graph, "habit review Friday", min_score: 0.0).find! { |row| row["item_id"].as_s == target.id }

    {
      "artifact_id"           => JSON::Any.new(target.id),
      "demoted_multiplier"    => JSON::Any.new(demoted["reliability_multiplier"].as_f),
      "restored_multiplier"   => JSON::Any.new(restored["reliability_multiplier"].as_f),
      "demoted_score_lowered" => JSON::Any.new(demoted["score"].as_f < demoted["raw_score"].as_f),
      "restored_score_equal"  => JSON::Any.new(restored["score"].as_f == restored["raw_score"].as_f),
    }
  end

  private def self._date_of(timestamp : String) : String
    timestamp[0, 10]
  end

  # Port of memory_gateway.backend.clear_all_backends — reset the
  # graph-backed store's process state (embedding registry).
  def self._clear_all_backends : Nil
    Chronicle::Packs::MemoryGateway::Backend.clear_embedding_services
    Chronicle::Packs::MemoryGateway::Backend.clear_embedder
  end
end
