require "chronicle"
require "json"
require "crypto/subtle"
require "http/server"

module Chronicle::Packs::DemoServer
  # ActiveGraph Inspector Demo Server (upstream packs/demo_server.py) — the
  # HTTP REST surface over the assembled stack.
  #
  # The port keeps the module-level helpers and the Handler dispatch as an
  # in-process `Chronicle::Packs::DemoServer` module: a runtime is built over
  # a memory store with the assistant bundle, and the endpoints are driven
  # directly (the port's analog of upstream's `_EXECUTOR.run` — no
  # subprocess, no socket dependency in tests). `main` binds a real
  # `HTTP::Server` on port 7788 (or `ACTIVEGRAPH_PORT`).
  #
  # Divergences (see plans/parity.md):
  # - Runtime state is module-level but constructed lazily via
  #   `reset_runtime`; tests build a fresh runtime and a Handler bound to it
  #   instead of a process singleton.
  # - `reset_runtime` uses the ported `Bundles.build_assistant` over a memory
  #   store (upstream persists to a SQLite event-log file and resumes via
  #   Runtime.load); the endpoint surface is unchanged.
  # - Endpoints needing deferred seams (OAuth managed source, MCP outbound
  #   registration, evolution boot) return the same 4xx/5xx shapes with a
  #   clear message when the seam is not wired.

  TONES           = {"neutral", "warm", "direct", "formal", "casual", "technical"}
  VERBOSITIES     = {"concise", "balanced", "detailed"}
  FORMALITIES     = {"informal", "neutral", "formal"}
  GOAL_PRIORITIES = {"low", "medium", "high", "critical"}
  GOAL_STATUSES   = {"active", "paused", "completed", "cancelled"}

  # Env vars that must never be overwritten via POST /secrets.
  RESERVED_ENV_NAMES = {
    "PATH", "LD_PRELOAD", "LD_LIBRARY_PATH", "PYTHONPATH", "PYTHONHOME",
    "HOME", "SHELL", "IFS", "BASH_ENV", "ENV", "PWD", "PORT",
  }

  # The chat provider keys the demo understands (upstream
  # chat/llm.SUPPORTED_PROVIDERS), mapped to their env var names.
  PROVIDER_KEY_ENVS = {
    "anthropic" => "ANTHROPIC_API_KEY",
    "openai"    => "OPENAI_API_KEY",
  }

  # Provider display labels (upstream chat/llm labels).
  PROVIDER_LABELS = {
    "openai"    => "OpenAI",
    "anthropic" => "Anthropic",
  }

  # ---- module state ------------------------------------------------------

  class_property _rt : Chronicle::Runtime(Chronicle::Packs::Bundles::BundleModel)? = nil
  class_property _frames : Hash(String, Hash(String, JSON::Any)) = {} of String => Hash(String, JSON::Any)
  class_property _chat_config : Hash(String, JSON::Any) = {} of String => JSON::Any
  class_property _chat_allow_list : Array(String) = [] of String
  class_property _approval_token : String = ""

  # ---- time / path helpers ----------------------------------------------

  def self._ts : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # ---- serialization helpers --------------------------------------------

  # Recursively convert a value into JSON-safe primitives (upstream
  # _safe_json). The runtime data is already JSON, so this normalizes the
  # raw value's structure (keys stringified, values recursed).
  def self._safe_json(value : JSON::Any) : JSON::Any
    raw = value.raw
    if raw.is_a?(Hash)
      JSON::Any.new(raw.to_h.transform_keys(&.to_s).transform_values { |v| _safe_json(v) })
    elsif raw.is_a?(Array)
      JSON::Any.new(raw.map { |v| _safe_json(v) })
    else
      value
    end
  end

  def self._event_to_dict(event : Chronicle::Event) : Hash(String, JSON::Any)
    payload = begin
      JSON.parse(event.payload).as_h
    rescue
      {} of String => JSON::Any
    end
    pack_name = nil
    behavior_name = nil
    object_id = nil
    actor = event.actor
    if actor.is_a?(Hash)
      pack_name = actor["pack"]?.try(&.as_s?)
      behavior_name = actor["behavior"]?.try(&.as_s?)
    end
    object_type = payload["object_type"]?.try(&.as_s?) || payload["type"]?.try(&.as_s?)
    if object_type
      object_id = payload["object_id"]?.try(&.as_s?) || payload["id"]?.try(&.as_s?)
    end
    {
      "id"            => JSON::Any.new(event.id),
      "event_type"    => JSON::Any.new(event.type),
      "timestamp"     => JSON::Any.new(event.timestamp.to_s("%Y-%m-%dT%H:%M:%SZ")),
      "pack"          => pack_name ? JSON::Any.new(pack_name) : JSON::Any.new(nil),
      "behavior_name" => behavior_name ? JSON::Any.new(behavior_name) : JSON::Any.new(nil),
      "frame_id"      => event.frame_id ? JSON::Any.new(event.frame_id) : JSON::Any.new(nil),
      "object_type"   => object_type ? JSON::Any.new(object_type) : JSON::Any.new(nil),
      "object_id"     => object_id ? JSON::Any.new(object_id) : JSON::Any.new(nil),
      "payload"       => _safe_json(JSON::Any.new(payload)),
    }
  end

  def self._object_to_dict(graph : Chronicle::GraphProjection, obj : Chronicle::GraphObject) : Hash(String, JSON::Any)
    pack_name = _pack_for_type(graph, obj.type)
    data = begin
      JSON.parse(obj.data).as_h
    rescue
      {} of String => JSON::Any
    end
    {
      "id"         => JSON::Any.new(obj.id),
      "type"       => JSON::Any.new(obj.type),
      "pack"       => JSON::Any.new(pack_name),
      "data"       => _safe_json(JSON::Any.new(data)),
      "created_at" => JSON::Any.new(obj.provenance.created_by),
    }
  end

  # Which registered pack declares this object type (upstream walks
  # rt.loaded_packs().object_types).
  def self._pack_for_type(graph : Chronicle::GraphProjection, type : String) : String
    Registry.discover.each do |discovered|
      discovered.pack.object_types.each do |obj_type|
        return discovered.name if obj_type.name == type
      end
    end
    "unknown"
  end

  def self._relation_to_dict(rel : Chronicle::GraphRelation) : Hash(String, JSON::Any)
    {
      "id"        => JSON::Any.new(rel.id),
      "type"      => JSON::Any.new(rel.type),
      "source_id" => JSON::Any.new(rel.from_id),
      "target_id" => JSON::Any.new(rel.to_id),
      "data"      => JSON::Any.new({} of String => JSON::Any),
    }
  end

  def self._pack_to_dict(pack : Chronicle::Packs::Pack) : Hash(String, JSON::Any)
    behaviors = pack.behaviors.map do |b|
      {
        "name"         => JSON::Any.new(b.name),
        "trigger"      => JSON::Any.new(b.event_types.first? || "object.created"),
        "description"  => JSON::Any.new(nil),
        "creates"      => JSON::Any.new(b.creates.map { |create| JSON::Any.new(create) }),
        "capabilities" => JSON::Any.new([] of JSON::Any),
      }
    end
    object_types = pack.object_types.map do |obj_type|
      {
        "name"        => JSON::Any.new(obj_type.name),
        "description" => JSON::Any.new(obj_type.description),
      }
    end
    relation_types = pack.relation_types.map do |rel_type|
      {
        "name"         => JSON::Any.new(rel_type.name),
        "source_types" => JSON::Any.new(rel_type.source_types.map { |src| JSON::Any.new(src) }),
        "target_types" => JSON::Any.new(rel_type.target_types.map { |tgt| JSON::Any.new(tgt) }),
        "description"  => JSON::Any.new(rel_type.description),
      }
    end
    {
      "name"           => JSON::Any.new(pack.name),
      "version"        => JSON::Any.new(pack.version),
      "description"    => JSON::Any.new(pack.description),
      "object_types"   => JSON::Any.new(object_types.map { |v| JSON::Any.new(v) }),
      "relation_types" => JSON::Any.new(relation_types.map { |v| JSON::Any.new(v) }),
      "behaviors"      => JSON::Any.new(behaviors.map { |v| JSON::Any.new(v) }),
    }
  end

  # ---- approval channel auth (gate 4) ------------------------------------

  def self.check_approval_auth(graph : Chronicle::GraphProjection, auth_header : String, *, evolution_on : Bool, token : String) : {Bool, String}
    if !token.empty?
      presented = auth_header.starts_with?("Bearer ") ? auth_header["Bearer ".size..].strip : ""
      if !presented.empty? && Crypto::Subtle.constant_time_compare(presented, token)
        return {true, ""}
      end
      reason = presented.empty? ? "missing bearer token" : "bearer token mismatch"
    elsif evolution_on
      reason = "no approval token configured while evolution is ON; " \
               "self-modification approvals over an unauthenticated " \
               "channel must not exist (set ACTIVEGRAPH_APPROVAL_TOKEN)"
    else
      return {true, ""}
    end
    begin
      graph.add_object("approval_auth_denial", JSON.build do |json|
        json.object do
          json.field "reason", reason
          json.field "path", "/approvals"
          json.field "at", _ts
        end
      end)
    rescue
    end
    {false, reason}
  end

  # ---- profile helpers ---------------------------------------------------

  def self._active_profile_id(graph : Chronicle::GraphProjection) : String?
    profiles = graph.objects(type: "agent_profile")
    profiles.each do |profile|
      data = JSON.parse(profile.data).as_h
      return profile.id if data["active"]?.try(&.as_bool?) == true
    end
    profiles.first?.try(&.id)
  end

  def self._owned_profile_object(graph : Chronicle::GraphProjection, oid : String, expected_type : String, pid : String) : Chronicle::GraphObject?
    obj = graph.get_object(oid)
    return nil if obj.nil? || obj.type != expected_type
    return nil unless JSON.parse(obj.data).as_h["profile_id"]?.try(&.as_s?) == pid
    obj
  end

  def self._global_personality_obj(graph : Chronicle::GraphProjection, profile_id : String) : Chronicle::GraphObject?
    graph.objects(type: "personality_profile").find do |personality|
      data = JSON.parse(personality.data).as_h
      data["profile_id"]?.try(&.as_s?) == profile_id &&
        data["applies_to_channel"]?.try(&.as_s?).nil? &&
        data["applies_to_audience_role"]?.try(&.as_s?).nil?
    end
  end

  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream profile assembly
  def self._profile_payload(graph : Chronicle::GraphProjection) : Hash(String, JSON::Any)
    pid = _active_profile_id(graph)
    if pid.nil?
      return {
        "exists"       => JSON::Any.new(false),
        "profile"      => JSON::Any.new(nil),
        "personality"  => JSON::Any.new(nil),
        "goals"        => JSON::Any.new([] of JSON::Any),
        "instructions" => JSON::Any.new([] of JSON::Any),
      }
    end

    profile_obj = graph.get_object(pid)
    pdata = profile_obj ? (JSON.parse(profile_obj.data).as_h rescue {} of String => JSON::Any) : {} of String => JSON::Any
    profile = {
      "id"                      => JSON::Any.new(pid),
      "name"                    => JSON::Any.new(pdata["name"]?.try(&.as_s?) || ""),
      "mission"                 => JSON::Any.new(pdata["mission"]?.try(&.as_s?) || ""),
      "personality_description" => JSON::Any.new(pdata["personality_description"]?.try(&.as_s?) || ""),
      "owner_name"              => pdata["owner_name"]? || JSON::Any.new(nil),
      "version"                 => JSON::Any.new((pdata["version"]?.try(&.as_s?) || "1")),
      "active"                  => JSON::Any.new(pdata["active"]?.try(&.as_bool?) == true || pdata["active"]?.nil?),
    }

    goals = [] of JSON::Any
    instructions = [] of JSON::Any
    personality : JSON::Any? = nil
    graph.objects.each do |obj|
      next if obj.type != "goal" && obj.type != "standing_instruction" && obj.type != "personality_profile"
      data = JSON.parse(obj.data).as_h
      next unless data["profile_id"]?.try(&.as_s?) == pid
      case obj.type
      when "goal"
        goals << JSON::Any.new({
          "id"       => JSON::Any.new(obj.id),
          "text"     => JSON::Any.new(data["text"]?.try(&.as_s?) || ""),
          "priority" => JSON::Any.new(data["priority"]?.try(&.as_s?) || "medium"),
          "status"   => JSON::Any.new(data["status"]?.try(&.as_s?) || "active"),
          "domain"   => data["domain"]? || JSON::Any.new(nil),
        })
      when "standing_instruction"
        instructions << JSON::Any.new({
          "id"                       => JSON::Any.new(obj.id),
          "text"                     => JSON::Any.new(data["text"]?.try(&.as_s?) || ""),
          "scope"                    => JSON::Any.new(data["scope"]?.try(&.as_s?) || "global"),
          "priority"                 => JSON::Any.new(data["priority"]?.try(&.as_i?) || 50),
          "active"                   => JSON::Any.new(data["active"]?.try(&.as_bool?) == true || data["active"]?.nil?),
          "applies_to_channel"       => data["applies_to_channel"]? || JSON::Any.new(nil),
          "applies_to_audience_role" => data["applies_to_audience_role"]? || JSON::Any.new(nil),
        })
      when "personality_profile"
        is_global = data["applies_to_channel"]?.nil? && data["applies_to_audience_role"]?.nil?
        cand = {
          "id"        => JSON::Any.new(obj.id),
          "tone"      => JSON::Any.new(data["tone"]?.try(&.as_s?) || "neutral"),
          "verbosity" => JSON::Any.new(data["verbosity"]?.try(&.as_s?) || "balanced"),
          "formality" => JSON::Any.new(data["formality"]?.try(&.as_s?) || "neutral"),
        }
        personality = JSON::Any.new(cand) if personality.nil? || is_global
      end
    end

    {
      "exists"       => JSON::Any.new(true),
      "profile"      => JSON::Any.new(profile),
      "personality"  => personality || JSON::Any.new(nil),
      "goals"        => JSON::Any.new(goals),
      "instructions" => JSON::Any.new(instructions),
    }
  end

  # ---- secrets / chat-config payloads ------------------------------------

  def self._secrets_payload(graph : Chronicle::GraphProjection) : Hash(String, JSON::Any)
    credentials = [] of JSON::Any
    graph.objects(type: "credential_ref").each do |ref|
      data = JSON.parse(ref.data).as_h
      name = data["name"]?.try(&.as_s?)
      credentials << JSON::Any.new({
        "id"            => JSON::Any.new(ref.id),
        "name"          => name ? JSON::Any.new(name) : JSON::Any.new(nil),
        "provider_hint" => data["provider_hint"]? || JSON::Any.new(nil),
        "scope"         => data["scope"]? || JSON::Any.new(nil),
        "value_present" => JSON::Any.new(!name.nil? && !ENV[name]?.nil? && !ENV[name].empty?),
        "last_used_at"  => data["last_used_at"]? || JSON::Any.new(nil),
        "use_count"     => JSON::Any.new(data["use_count"]?.try(&.as_i?) || 0),
      })
    end
    credentials.sort_by! { |cred| cred["name"]?.try(&.as_s?) || "" }
    {"credentials" => JSON::Any.new(credentials), "total" => JSON::Any.new(credentials.size)}
  end

  def self._chat_config_payload : Hash(String, JSON::Any)
    providers = PROVIDER_KEY_ENVS.keys.sort!.map do |pid|
      env = PROVIDER_KEY_ENVS[pid]
      {
        "id"          => JSON::Any.new(pid),
        "label"       => JSON::Any.new(PROVIDER_LABELS[pid]? || pid.capitalize),
        "key_env"     => JSON::Any.new(env),
        "key_present" => JSON::Any.new(!ENV[env]?.nil? && !ENV[env].empty?),
      }
    end
    config = _chat_config
    {
      "mode"        => JSON::Any.new(config["mode"]?.try(&.as_s?) || "mock"),
      "provider"    => config["provider"]? || JSON::Any.new(nil),
      "model"       => config["model"]? || JSON::Any.new(nil),
      "key_present" => JSON::Any.new(config["key_present"]?.try(&.as_bool?) || false),
      "providers"   => JSON::Any.new(providers.map { |v| JSON::Any.new(v) }),
    }
  end

  def self._current_allow_list : Array(String)
    _chat_allow_list
  end

  # ---- demo seeding ------------------------------------------------------

  def self._seed_demo(graph : Chronicle::GraphProjection) : Nil
    graph.add_object("source", %({"kind":"chat_message","content":"What is the current deal status for Northwind Robotics?","channel":"chat","sender_ref":"user:alice"}))
    graph.add_object("source", %({"kind":"email","content":"Please review the attached term sheet for the Series B round.","channel":"email","sender_ref":"founder@northwind.ai"}))
    graph.add_object("source", %({"kind":"meeting_note","content":"Kickoff call with Northwind team. Strong ARR traction, 3x YoY.","channel":"internal","sender_ref":"user:bob"}))
    graph.add_object("source", %({"kind":"url","content":"https://arxiv.org/abs/2312.00752","channel":"api","sender_ref":"user:alice"}))
  end

  # Build a fresh demo runtime: the assistant bundle over a memory store,
  # seeded with demo objects. No default profile is seeded (upstream
  # `build_messaging_assistant`); `/profile/seed` creates it on demand.
  def self.reset_runtime : Chronicle::Runtime(Chronicle::Packs::Bundles::BundleModel)
    Chronicle::Packs::IdentityAuth.clear_principal_registry
    _store, graph, rt = Chronicle::Packs::Bundles.build_assistant(
      memory_gateway_settings: Chronicle::Packs::MemoryGateway::MemoryGatewaySettings.new(backend_url: ":memory:"),
      chat_settings: Chronicle::Packs::Chat::ChatSettings.new(llm_provider: "mock", auto_approve_responses: true),
      seed_profile: false,
    )
    _seed_demo(graph)
    rt.run_until_idle
    self._rt = rt
    rt
  end

  # The live runtime (lazily built).
  def self._get_rt : Chronicle::Runtime(Chronicle::Packs::Bundles::BundleModel)
    if (rt = _rt).nil?
      reset_runtime
    else
      rt
    end
  end

  # ---- Handler -----------------------------------------------------------

  # In-process request handler. Response is captured on `response_status` /
  # `response_body` so tests drive the dispatch without a socket; `main`
  # adapts it to `HTTP::Server::Context`.
  class Handler
    getter response_status : Int32 = 200
    getter response_body : String? = nil

    def initialize(@rt : Chronicle::Runtime(Chronicle::Packs::Bundles::BundleModel))
    end

    def graph : Chronicle::GraphProjection
      @rt.graph || raise Chronicle::Packs::PackError.new("demo runtime has no graph")
    end

    def _send_json(data : JSON::Any | Hash(String, JSON::Any) | Array(JSON::Any) | String | Int32 | Float64 | Bool | Nil, status : Int32 = 200)
      @response_status = status
      @response_body = data.to_json
    end

    def _send_error(msg : String, status : Int32 = 500)
      _send_json({"error" => JSON::Any.new(msg)}, status)
    end

    def _send_html(text : String, status : Int32 = 200)
      @response_status = status
      @response_body = text
    end

    def _path(path : String) : String
      if i = path.index('?')
        path[0, i]
      else
        path
      end
    end

    def _parse_qs(path : String) : Hash(String, String)
      result = {} of String => String
      if i = path.index('?')
        query = path[(i + 1)..]
        query.split('&').each do |pair|
          k, _, v = pair.partition('=')
          next if k.empty?
          result[URI.decode_www_form(k)] = URI.decode_www_form(v)
        end
      end
      result
    end

    # GET dispatch. `body` is nil for GET; query params are parsed.
    # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream GET routing
    def _dispatch_get(path : String, qs : Hash(String, String)) : Nil
      case _path(path)
      when "/trace"                     then _handle_trace(qs)
      when "/graph"                     then _handle_graph(qs)
      when "/packs"                     then _handle_packs
      when "/frames"                    then _handle_frames
      when "/summary"                   then _handle_summary
      when "/chat/config"               then _handle_chat_config_get
      when "/secrets"                   then _handle_secrets_get
      when "/profile"                   then _handle_profile_get
      when "/approvals"                 then _handle_approvals_get
      when "/approvals/review"          then _handle_approvals_review_get(qs)
      when "/sessions"                  then _handle_sessions_get
      when "/channels/whatsapp/webhook" then _handle_whatsapp_verify(qs)
      when "/capabilities"              then _handle_capabilities_get
      when "/health"                    then _send_json({"status" => JSON::Any.new("ok")})
      else                                   _send_error("Not found", 404)
      end
    end

    # POST dispatch.
    # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream POST routing
    def _dispatch_post(path : String, body : Hash(String, JSON::Any)) : Nil
      case _path(path)
      when "/chat"                       then _handle_chat(body)
      when "/reset"                      then _handle_reset
      when "/chat/config"                then _handle_chat_config_post(body)
      when "/secrets"                    then _handle_secrets_post(body)
      when "/profile"                    then _handle_profile_post(body)
      when "/profile/seed"               then _handle_profile_seed
      when "/profile/personality"        then _handle_profile_personality_post(body)
      when "/profile/goal"               then _handle_profile_goal_post(body)
      when "/profile/goal/delete"        then _handle_profile_goal_delete(body)
      when "/profile/instruction"        then _handle_profile_instruction_post(body)
      when "/profile/instruction/delete" then _handle_profile_instruction_delete(body)
      when "/approvals"                  then _handle_approvals_post(body)
      when "/channels/telegram/update"   then _handle_telegram_update(body)
      when "/channels/whatsapp/webhook"  then _handle_whatsapp_webhook(body)
      when "/mcp"                        then _handle_mcp(body)
      when "/secrets/oauth/start"        then _handle_oauth_start(body)
      when "/secrets/oauth/poll"         then _handle_oauth_poll(body)
      else                                    _send_error("Not found", 404)
      end
    end

    # ---- endpoints --------------------------------------------------------

    def _handle_trace(qs : Hash(String, String)) : Nil
      limit = qs["limit"]?.try(&.to_i?) || 200
      offset = qs["offset"]?.try(&.to_i?) || 0
      pack_filter = qs["pack"]?
      frame_filter = qs["frame_id"]?
      type_filter = qs["event_type"]?

      events = graph.events.map { |e| DemoServer._event_to_dict(e) }
      if pack_filter
        events = events.select { |e| e["pack"]?.try(&.as_s?) == pack_filter }
      end
      if frame_filter
        events = events.select { |e| e["frame_id"]?.try(&.as_s?) == frame_filter }
      end
      if type_filter
        events = events.select { |e| (e["event_type"]?.try(&.as_s?) || "").includes?(type_filter) }
      end

      total = events.size
      page = events[offset, limit]

      _send_json({
        "events" => JSON::Any.new(page.map { |v| JSON::Any.new(v) }),
        "total"  => JSON::Any.new(total),
        "offset" => JSON::Any.new(offset),
        "limit"  => JSON::Any.new(limit),
      })
    end

    def _handle_graph(qs : Hash(String, String)) : Nil
      pack_filter = qs["pack"]?
      objects = graph.all_objects.map { |obj| DemoServer._object_to_dict(graph, obj) }
      relations = graph.all_relations.map { |rel| DemoServer._relation_to_dict(rel) }

      if pack_filter
        objects = objects.select { |obj| obj["pack"]?.try(&.as_s?) == pack_filter }
        obj_ids = objects.map(&.["id"].as_s).to_set
        relations = relations.select { |rel| obj_ids.includes?(rel["source_id"].as_s) || obj_ids.includes?(rel["target_id"].as_s) }
      end

      _send_json({
        "objects"        => JSON::Any.new(objects.map { |v| JSON::Any.new(v) }),
        "relations"      => JSON::Any.new(relations.map { |v| JSON::Any.new(v) }),
        "object_count"   => JSON::Any.new(objects.size),
        "relation_count" => JSON::Any.new(relations.size),
      })
    end

    def _handle_packs : Nil
      packs = [] of JSON::Any
      Registry.discover.each do |discovered|
        packs << JSON::Any.new(DemoServer._pack_to_dict(discovered.pack))
      end
      _send_json({"packs" => JSON::Any.new(packs), "total" => JSON::Any.new(packs.size)})
    end

    def _handle_frames : Nil
      frames = DemoServer._frames.values.sort_by! { |frame| frame["started_at"]?.try(&.as_s?) || "" }.reverse!
      _send_json({"frames" => JSON::Any.new(frames.map { |v| JSON::Any.new(v) }), "total" => JSON::Any.new(frames.size)})
    end

    def _handle_summary : Nil
      objects = graph.all_objects
      relations = graph.all_relations
      events = graph.events

      type_counts = {} of String => Hash(String, JSON::Any)
      objects.each do |obj|
        key = "#{obj.type}|#{DemoServer._pack_for_type(graph, obj.type)}"
        entry = type_counts[key]? || {
          "type"  => JSON::Any.new(obj.type),
          "pack"  => JSON::Any.new(DemoServer._pack_for_type(graph, obj.type)),
          "count" => JSON::Any.new(0),
        }
        entry["count"] = JSON::Any.new(entry["count"].as_i + 1)
        type_counts[key] = entry
      end

      _send_json({
        "object_count"   => JSON::Any.new(objects.size),
        "relation_count" => JSON::Any.new(relations.size),
        "event_count"    => JSON::Any.new(events.size),
        "pack_count"     => JSON::Any.new(Registry.discover.size),
        "frame_count"    => JSON::Any.new(DemoServer._frames.size),
        "by_type"        => JSON::Any.new(type_counts.values.map { |v| JSON::Any.new(v) }),
        "runtime_ready"  => JSON::Any.new(true),
      })
    end

    def _handle_chat(body : Hash(String, JSON::Any)) : Nil
      content = (body["content"]?.try(&.as_s?) || "").strip
      if content.empty?
        _send_error("content is required", 400)
        return
      end

      user_ref = body["user_ref"]?.try(&.as_s?) || "user:inspector"
      session_id = body["session_id"]?.try(&.as_s?)
      frame_id = "chat_#{Random::Secure.hex(8)}"

      objects_before = graph.all_objects.map(&.id).to_set
      events_before = graph.events.size

      Chronicle::Packs::Chat.submit_chat_input_fn(
        graph,
        user_ref: user_ref,
        content: content,
        session_id: session_id,
        frame_id: frame_id,
      )
      @rt.run_until_idle

      objects_after = graph.all_objects
      new_obj_ids = objects_after.select { |obj| !objects_before.includes?(obj.id) }.map(&.id)
      events_after = graph.events.size

      DemoServer._frames[frame_id] = {
        "id"          => JSON::Any.new(frame_id),
        "status"      => JSON::Any.new("completed"),
        "frame_type"  => JSON::Any.new("chat"),
        "started_at"  => JSON::Any.new(DemoServer._ts),
        "ended_at"    => JSON::Any.new(DemoServer._ts),
        "event_count" => JSON::Any.new(events_after - events_before),
        "events"      => JSON::Any.new(graph.events[events_before..].map { |evt| JSON::Any.new(DemoServer._event_to_dict(evt)) }),
      }

      turns = objects_after.select { |obj| obj.type == "chat_turn" && (JSON.parse(obj.data).as_h["frame_id"]?.try(&.as_s?) == frame_id) }
      turns.sort_by! { |turn| JSON.parse(turn.data).as_h["turn_number"]?.try(&.as_i?) || 0 }
      turn = turns.last?
      reply = turn.try { |turn_obj| (JSON.parse(turn_obj.data).as_h["assistant_message"]?.try(&.as_s?) || "").strip } || ""
      if reply.empty?
        reply = "No assistant reply was produced for this message."
      end
      resolved_session = turn.try { |turn_obj| JSON.parse(turn_obj.data).as_h["session_id"]?.try(&.as_s?) }

      _send_json({
        "content"      => JSON::Any.new(reply),
        "frame_id"     => JSON::Any.new(frame_id),
        "user_message" => JSON::Any.new(content),
        "session_id"   => JSON::Any.new(resolved_session || session_id),
        "turn_id"      => turn ? JSON::Any.new(turn.id) : JSON::Any.new(nil),
        "llm_mode"     => JSON::Any.new(DemoServer._chat_config["mode"]?.try(&.as_s?) || "mock"),
        "event_count"  => JSON::Any.new(events_after - events_before),
        "new_objects"  => JSON::Any.new(new_obj_ids.map { |id| JSON::Any.new(id) }),
      })
    end

    def _handle_chat_config_get : Nil
      DemoServer._get_rt
      _send_json(DemoServer._chat_config_payload)
    end

    def _handle_chat_config_post(body : Hash(String, JSON::Any)) : Nil
      provider = body["provider"]?.try(&.as_s?)
      model = body["model"]?.try(&.as_s?)

      if provider
        provider = provider.strip.downcase
        if !provider.empty? && !PROVIDER_KEY_ENVS.has_key?(provider)
          _send_error("Unsupported provider '#{provider}'. Supported: #{PROVIDER_KEY_ENVS.keys.sort!.join(", ")}.", 400)
          return
        end
        if provider.empty?
          ENV.delete("CHAT_LLM_PROVIDER")
        else
          ENV["CHAT_LLM_PROVIDER"] = provider
        end
      end

      if model
        model = model.strip
        if model.empty?
          ENV.delete("CHAT_LLM_MODEL")
        else
          ENV["CHAT_LLM_MODEL"] = model
        end
      end

      _refresh_chat_provider
      _send_json(DemoServer._chat_config_payload)
    end

    def _handle_secrets_get : Nil
      _send_json(DemoServer._secrets_payload(graph))
    end

    def _handle_secrets_post(body : Hash(String, JSON::Any)) : Nil
      name = (body["name"]?.try(&.as_s?) || "").strip.upcase
      value = body["value"]?.try(&.as_s?)
      provider_hint = (body["provider_hint"]?.try(&.as_s?) || "").strip.downcase

      if name.empty?
        _send_error("name is required", 400)
        return
      end
      if value.nil? || value.empty?
        _send_error("value is required", 400)
        return
      end
      if RESERVED_ENV_NAMES.includes?(name)
        _send_error("'#{name}' is a reserved system variable and cannot be set here.", 400)
        return
      end

      ENV[name] = value

      existing = graph.objects(type: "credential_ref").any? do |ref|
        JSON.parse(ref.data).as_h["name"]?.try(&.as_s?) == name
      end
      unless existing
        graph.add_object("credential_ref", %({"name":"#{name}","scope":"read","provider_hint":#{provider_hint.empty? ? "null" : %("#{provider_hint}")}}))
      end

      _refresh_chat_provider

      payload = DemoServer._secrets_payload(graph)
      payload["chat_config"] = JSON::Any.new(DemoServer._chat_config_payload)
      _send_json(payload)
    end

    def _handle_profile_get : Nil
      _send_json(DemoServer._profile_payload(graph))
    end

    def _handle_profile_seed : Nil
      pid = DemoServer._active_profile_id(graph)
      if pid.nil?
        Chronicle::Packs::Bundles.seed_default_profile(@rt)
        @rt.run_until_idle
        Chronicle::Packs::AgentProfile.rebuild_profile_registry(graph)
      end
      _send_json(DemoServer._profile_payload(graph))
    end

    def _handle_profile_post(body : Hash(String, JSON::Any)) : Nil
      pid = DemoServer._active_profile_id(graph)
      if pid.nil?
        _send_error("No profile exists yet — create one first.", 404)
        return
      end

      updates = {} of String => JSON::Any
      {"name", "mission", "personality_description", "owner_name"}.each do |field|
        next unless body.has_key?(field)
        v = body[field]?
        if field == "owner_name"
          updates[field] = v.nil? ? JSON::Any.new(nil) : JSON::Any.new(v.as_s.strip)
        else
          updates[field] = JSON::Any.new(v.nil? ? "" : v.as_s)
        end
      end

      if (updates["name"]?.try(&.as_s?) || "").strip.empty? && updates.has_key?("name")
        _send_error("name cannot be empty", 400)
        return
      end

      unless updates.empty?
        current = graph.get_object(pid)
        merged = current.try { |obj| JSON.parse(obj.data).as_h } || {} of String => JSON::Any
        merged = merged.merge(updates)
        graph.patch_object(pid, merged.to_json)
        @rt.run_until_idle
        Chronicle::Packs::AgentProfile.rebuild_profile_registry(graph)
      end
      _send_json(DemoServer._profile_payload(graph))
    end

    def _handle_profile_personality_post(body : Hash(String, JSON::Any)) : Nil
      pid = DemoServer._active_profile_id(graph)
      if pid.nil?
        _send_error("No profile exists yet — create one first.", 404)
        return
      end

      tone = body["tone"]?.try(&.as_s?) || "neutral"
      verbosity = body["verbosity"]?.try(&.as_s?) || "balanced"
      formality = body["formality"]?.try(&.as_s?) || "neutral"
      unless TONES.includes?(tone)
        _send_error("tone must be one of #{TONES.to_a.join(", ")}", 400)
        return
      end
      unless VERBOSITIES.includes?(verbosity)
        _send_error("verbosity must be one of #{VERBOSITIES.to_a.join(", ")}", 400)
        return
      end
      unless FORMALITIES.includes?(formality)
        _send_error("formality must be one of #{FORMALITIES.to_a.join(", ")}", 400)
        return
      end

      existing = DemoServer._global_personality_obj(graph, pid)
      if existing
        current = JSON.parse(existing.data).as_h
        graph.patch_object(existing.id, current.merge({"tone" => JSON::Any.new(tone), "verbosity" => JSON::Any.new(verbosity), "formality" => JSON::Any.new(formality)}).to_json)
      else
        graph.add_object("personality_profile", JSON.build do |json|
          json.object do
            json.field "tone", tone
            json.field "verbosity", verbosity
            json.field "formality", formality
            json.field "applies_to_channel", JSON::Any.new(nil)
            json.field "applies_to_audience_role", JSON::Any.new(nil)
            json.field "profile_id", pid
            json.field "metadata", JSON::Any.new({} of String => JSON::Any)
          end
        end)
      end
      @rt.run_until_idle
      Chronicle::Packs::AgentProfile.rebuild_profile_registry(graph)
      _send_json(DemoServer._profile_payload(graph))
    end

    # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream goal editor
    def _handle_profile_goal_post(body : Hash(String, JSON::Any)) : Nil
      pid = DemoServer._active_profile_id(graph)
      if pid.nil?
        _send_error("No profile exists yet — create one first.", 404)
        return
      end

      gid = body["id"]?.try(&.as_s?)
      text = (body["text"]?.try(&.as_s?) || "").strip
      priority = body["priority"]?.try(&.as_s?) || "medium"
      status = body["status"]?.try(&.as_s?) || "active"
      domain = body["domain"]?.try(&.as_s?)

      if text.empty?
        _send_error("text is required", 400)
        return
      end
      unless GOAL_PRIORITIES.includes?(priority)
        _send_error("priority must be one of #{GOAL_PRIORITIES.to_a.join(", ")}", 400)
        return
      end
      unless GOAL_STATUSES.includes?(status)
        _send_error("status must be one of #{GOAL_STATUSES.to_a.join(", ")}", 400)
        return
      end

      if gid && DemoServer._owned_profile_object(graph, gid, "goal", pid).nil?
        _send_error("Goal not found for the active profile.", 404)
        return
      end

      if gid
        current = JSON.parse(graph.get_object(gid).try(&.data) || "{}").as_h
        graph.patch_object(gid, current.merge({"text" => JSON::Any.new(text), "priority" => JSON::Any.new(priority), "status" => JSON::Any.new(status), "domain" => domain ? JSON::Any.new(domain) : JSON::Any.new(nil)}).to_json)
      else
        graph.add_object("goal", JSON.build do |json|
          json.object do
            json.field "text", text
            json.field "priority", priority
            json.field "status", status
            json.field "domain", domain ? JSON::Any.new(domain) : JSON::Any.new(nil)
            json.field "profile_id", pid
            json.field "metadata", JSON::Any.new({} of String => JSON::Any)
          end
        end)
      end
      @rt.run_until_idle
      Chronicle::Packs::AgentProfile.rebuild_profile_registry(graph)
      _send_json(DemoServer._profile_payload(graph))
    end

    def _handle_profile_goal_delete(body : Hash(String, JSON::Any)) : Nil
      gid = body["id"]?.try(&.as_s?)
      if gid.nil? || gid.empty?
        _send_error("id is required", 400)
        return
      end
      pid = DemoServer._active_profile_id(graph)
      if pid.nil? || DemoServer._owned_profile_object(graph, gid, "goal", pid).nil?
        _send_error("Goal not found for the active profile.", 404)
        return
      end
      graph.remove_object(gid)
      @rt.run_until_idle
      Chronicle::Packs::AgentProfile.rebuild_profile_registry(graph)
      _send_json(DemoServer._profile_payload(graph))
    end

    # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream instruction editor
    def _handle_profile_instruction_post(body : Hash(String, JSON::Any)) : Nil
      pid = DemoServer._active_profile_id(graph)
      if pid.nil?
        _send_error("No profile exists yet — create one first.", 404)
        return
      end

      iid = body["id"]?.try(&.as_s?)
      text = (body["text"]?.try(&.as_s?) || "").strip
      scope = (body["scope"]?.try(&.as_s?) || "global").strip
      scope = "global" if scope.empty?
      active = body["active"]?.nil? ? true : body["active"].as_bool
      channel = body["applies_to_channel"]?.try(&.as_s?)
      role = body["applies_to_audience_role"]?.try(&.as_s?)
      priority = body["priority"]?.try(&.as_i?) || 50

      if text.empty?
        _send_error("text is required", 400)
        return
      end
      unless 0 <= priority <= 100
        _send_error("priority must be between 0 and 100", 400)
        return
      end

      if iid && DemoServer._owned_profile_object(graph, iid, "standing_instruction", pid).nil?
        _send_error("Instruction not found for the active profile.", 404)
        return
      end

      if iid
        current = JSON.parse(graph.get_object(iid).try(&.data) || "{}").as_h
        graph.patch_object(iid, current.merge({
          "text"                     => JSON::Any.new(text),
          "scope"                    => JSON::Any.new(scope),
          "priority"                 => JSON::Any.new(priority),
          "active"                   => JSON::Any.new(active),
          "applies_to_channel"       => channel ? JSON::Any.new(channel) : JSON::Any.new(nil),
          "applies_to_audience_role" => role ? JSON::Any.new(role) : JSON::Any.new(nil),
        }).to_json)
      else
        graph.add_object("standing_instruction", JSON.build do |json|
          json.object do
            json.field "text", text
            json.field "scope", scope
            json.field "priority", priority
            json.field "active", active
            json.field "applies_to_channel", channel ? JSON::Any.new(channel) : JSON::Any.new(nil)
            json.field "applies_to_audience_role", role ? JSON::Any.new(role) : JSON::Any.new(nil)
            json.field "profile_id", pid
            json.field "metadata", JSON::Any.new({} of String => JSON::Any)
          end
        end)
      end
      @rt.run_until_idle
      Chronicle::Packs::AgentProfile.rebuild_profile_registry(graph)
      _send_json(DemoServer._profile_payload(graph))
    end

    def _handle_profile_instruction_delete(body : Hash(String, JSON::Any)) : Nil
      iid = body["id"]?.try(&.as_s?)
      if iid.nil? || iid.empty?
        _send_error("id is required", 400)
        return
      end
      pid = DemoServer._active_profile_id(graph)
      if pid.nil? || DemoServer._owned_profile_object(graph, iid, "standing_instruction", pid).nil?
        _send_error("Instruction not found for the active profile.", 404)
        return
      end
      graph.remove_object(iid)
      @rt.run_until_idle
      Chronicle::Packs::AgentProfile.rebuild_profile_registry(graph)
      _send_json(DemoServer._profile_payload(graph))
    end

    def _handle_sessions_get : Nil
      sessions = [] of JSON::Any
      graph.objects(type: "chat_session").each do |session_obj|
        data = JSON.parse(session_obj.data).as_h
        sessions << JSON::Any.new({
          "session_id" => JSON::Any.new(session_obj.id),
          "user_ref"   => data["user_ref"]? || JSON::Any.new(nil),
          "status"     => data["status"]? || JSON::Any.new(nil),
          "turn_count" => JSON::Any.new(data["turn_count"]?.try(&.as_i?) || 0),
          "started_at" => data["started_at"]? || JSON::Any.new(nil),
        })
      end
      sessions.sort_by! { |session| session["started_at"]?.try(&.as_s?) || "" }.reverse!
      _send_json({"sessions" => JSON::Any.new(sessions), "count" => JSON::Any.new(sessions.size)})
    end

    def _handle_capabilities_get : Nil
      entries = [] of JSON::Any
      ToolGateway::LocalRegistry::REGISTRY.each_value do |spec|
        entries << JSON::Any.new({
          "provider"   => JSON::Any.new(spec.provider_name),
          "capability" => JSON::Any.new(spec.capability_name),
          "risk_class" => JSON::Any.new(spec.risk_class),
          "origin"     => JSON::Any.new(spec.origin),
          "granted"    => JSON::Any.new(DemoServer._current_allow_list.includes?("#{spec.provider_name}.#{spec.capability_name}")),
        })
      end
      _send_json({"count" => JSON::Any.new(entries.size), "capabilities" => JSON::Any.new(entries)})
    end

    def _handle_approvals_get : Nil
      pending = ToolGateway.pending_approvals_fn(graph)
      recent_approvals = _decision_rows(graph, "capability_approval", "approved_at")
      recent_denials = _decision_rows(graph, "capability_denial", "denied_at")
      _send_json({
        "pending"          => JSON::Any.new(pending.map { |v| JSON::Any.new(v) }),
        "recent_approvals" => JSON::Any.new(recent_approvals),
        "recent_denials"   => JSON::Any.new(recent_denials),
      })
    end

    def _decision_rows(graph : Chronicle::GraphProjection, obj_type : String, ts_key : String) : Array(JSON::Any)
      rows = [] of JSON::Any
      graph.objects(type: obj_type).each do |decision|
        data = JSON.parse(decision.data).as_h
        rows << JSON::Any.new({
          "id"              => JSON::Any.new(decision.id),
          "call_id"         => data["call_id"]? || JSON::Any.new(nil),
          "capability_name" => JSON::Any.new(data["capability_name"]?.try(&.as_s?) || ""),
          "provider_name"   => JSON::Any.new(data["provider_name"]?.try(&.as_s?) || ""),
          ts_key            => data[ts_key]? || JSON::Any.new(nil),
          "decided_by"      => data["approver"]? || data["denier"]? || JSON::Any.new(nil),
          "policy_decision" => data["policy_decision"]? || JSON::Any.new(nil),
          "reason"          => data["reason"]? || JSON::Any.new(nil),
        })
      end
      rows.sort_by! { |row| row[ts_key]?.try(&.as_s?) || "" }.reverse!
      rows[0, 20]
    end

    def _handle_approvals_review_get(qs : Hash(String, String)) : Nil
      proposal_id = qs["proposal_id"]?.try(&.strip) || ""
      call_id = qs["call_id"]?.try(&.strip) || ""
      if call_id.empty? && !proposal_id.empty?
        # fall through
      elsif !call_id.empty? && proposal_id.empty?
        call = graph.get_object(call_id)
        if call
          proposal_id = (JSON.parse(call.data).as_h["input_data"]?.try(&.as_h) || {} of String => JSON::Any)["proposal_id"]?.try(&.as_s?) || ""
        end
      end
      if proposal_id.empty?
        _send_error("proposal_id (or call_id) is required", 400)
        return
      end
      begin
        review = Evolution::Review.build_review(graph, proposal_id)
      rescue KeyError | Chronicle::Packs::PackError
        _send_error("proposal not found", 404)
        return
      end
      _send_json(review)
    end

    # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream approval decision
    def _handle_approvals_post(body : Hash(String, JSON::Any)) : Nil
      auth_header = body["authorization"]?.try(&.as_s?) || ""
      ok, reason = DemoServer.check_approval_auth(
        graph,
        auth_header,
        evolution_on: ENV["ACTIVEGRAPH_EVOLUTION"]?.try(&.strip) == "1",
        token: DemoServer._approval_token,
      )
      unless ok
        _send_json({"error" => JSON::Any.new("approval channel unauthorized: #{reason}")}, 401)
        return
      end

      call_id = (body["call_id"]?.try(&.as_s?) || "").strip
      decision = (body["decision"]?.try(&.as_s?) || "").strip.downcase
      approver_ref = (body["approver_ref"]?.try(&.as_s?) || "user:inspector").strip

      if call_id.empty?
        _send_error("call_id is required", 400)
        return
      end
      unless decision.in?({"approve", "deny"})
        _send_error("decision must be 'approve' or 'deny'", 400)
        return
      end

      outcome = if decision == "approve"
                  ToolGateway.approve_capability_fn(graph, call_id, approver_ref, note: body["note"]?.try(&.as_s?) || "")
                else
                  ToolGateway.deny_capability_fn(graph, call_id, approver_ref, reason: body["reason"]?.try(&.as_s?) || "")
                end

      if outcome["ok"]?.try(&.as_bool?)
        @rt.run_until_idle
      end

      unless outcome["ok"]?.try(&.as_bool?)
        _send_json({"ok" => JSON::Any.new(false), "reason" => outcome["reason"]? || JSON::Any.new(nil)}, 409)
        return
      end

      call = graph.get_object(call_id)
      final_status = call.try { |call_obj| JSON.parse(call_obj.data).as_h["status"]? } || JSON::Any.new(nil)

      _send_json({
        "ok"          => JSON::Any.new(true),
        "decision"    => JSON::Any.new(decision),
        "call_id"     => JSON::Any.new(call_id),
        "call_status" => final_status,
        "approval_id" => outcome["approval_id"]? || JSON::Any.new(nil),
        "denial_id"   => outcome["denial_id"]? || JSON::Any.new(nil),
      })
    end

    def _handle_telegram_update(body : Hash(String, JSON::Any)) : Nil
      created = Chronicle::Packs::Telegram.submit_telegram_update_fn(graph, body)
      @rt.run_until_idle
      _send_json({"ok" => JSON::Any.new(true), "ingested" => JSON::Any.new(!created.nil?)})
    rescue ex
      _send_error("#{ex.class}: #{ex.message}", 500)
    end

    def _handle_whatsapp_verify(qs : Hash(String, String)) : Nil
      expected = ENV["WHATSAPP_VERIFY_TOKEN"]? || ""
      if !expected.empty? && qs["hub.mode"]? == "subscribe" && qs["hub.verify_token"]? == expected
        _send_html(qs["hub.challenge"]? || "", 200)
      else
        _send_error("verification failed", 403)
      end
    end

    def _handle_whatsapp_webhook(body : Hash(String, JSON::Any)) : Nil
      created = Chronicle::Packs::WhatsApp.submit_whatsapp_webhook_fn(graph, body)
      @rt.run_until_idle
      _send_json({"ok" => JSON::Any.new(true), "ingested" => JSON::Any.new(created.size)})
    rescue ex
      _send_error("#{ex.class}: #{ex.message}", 500)
    end

    def _handle_mcp(body : Hash(String, JSON::Any)) : Nil
      _send_error("MCP gateway not initialized (no outbound MCP servers configured)", 503)
    end

    def _handle_oauth_start(body : Hash(String, JSON::Any)) : Nil
      _send_error("managed OAuth source not wired in the port (deferred seam)", 501)
    end

    def _handle_oauth_poll(body : Hash(String, JSON::Any)) : Nil
      _send_error("managed OAuth source not wired in the port (deferred seam)", 501)
    end

    def _handle_reset : Nil
      DemoServer.reset_runtime
      _send_json({"success" => JSON::Any.new(true), "message" => JSON::Any.new("Runtime reset to initial demo state.")})
    end

    private def _refresh_chat_provider : Nil
      mode = "mock"
      provider = nil
      PROVIDER_KEY_ENVS.each_key do |pid|
        env = PROVIDER_KEY_ENVS[pid]
        if !ENV[env]?.nil? && !ENV[env].empty?
          mode = "live"
          provider = pid
          break
        end
      end
      config = if provider
                 model = ENV["CHAT_LLM_MODEL"]?
                 {
                   "mode"        => JSON::Any.new(mode),
                   "provider"    => JSON::Any.new(provider),
                   "model"       => model ? JSON::Any.new(model) : JSON::Any.new(nil),
                   "key_present" => JSON::Any.new(true),
                 }
               else
                 {"mode" => JSON::Any.new(mode), "provider" => JSON::Any.new(nil), "model" => JSON::Any.new(nil), "key_present" => JSON::Any.new(false)}
               end
      DemoServer._chat_config = config
      nil
    end
  end

  # ---- test seam for approval token --------------------------------------

  def self._set_approval_token(token : String) : Nil
    self._approval_token = token
  end

  def self._clear_approval_token : Nil
    self._approval_token = ""
  end

  # ---- real HTTP server entry point --------------------------------------

  def self.main(argv : Array(String)? = nil) : Int32
    args = argv || ARGV
    port = ENV["ACTIVEGRAPH_PORT"]?.try(&.to_i?) || 7788
    if args.size > 2 && args[0] == "--port"
      port = args[1].to_i
    end

    rt = reset_runtime
    handler = Handler.new(rt)

    server = HTTP::Server.new do |context|
      request = context.request
      path = request.path
      method = request.method

      if method == "GET"
        handler._dispatch_get(path, handler._parse_qs(path))
      elsif method == "POST"
        body = begin
          JSON.parse(request.body.try(&.gets_to_end) || "{}").as_h
        rescue
          {} of String => JSON::Any
        end
        handler._dispatch_post(path, body)
      elsif method == "OPTIONS"
        context.response.status_code = 200
        context.response.headers["Access-Control-Allow-Origin"] = "*"
        context.response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        context.response.headers["Access-Control-Allow-Headers"] = "Content-Type"
        context.response.close
        next
      else
        handler._send_error("Not found", 404)
      end

      status = handler.response_status
      body = handler.response_body || ""
      context.response.status_code = status
      context.response.headers["Content-Type"] = "application/json"
      context.response.headers["Access-Control-Allow-Origin"] = "*"
      context.response.print body
    end

    server.bind_tcp("0.0.0.0", port)
    server.listen
    0
  end
end
