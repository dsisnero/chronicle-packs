require "json"
require "time"

module Chronicle::Packs::AgentProfile
  # Agent Profile behaviors. Ported from upstream
  # packs/agent_profile/behaviors.py.
  #
  # Five registry recorders index profile objects by profile_id for fast
  # context assembly (no graph.objects scan). profile_context_provider
  # assembles a scoped ProfileContextView from a request; the two triggers
  # auto-create requests from auth_context.created / frame.created.

  # ------------------------------------------------------------------ registry

  # One profile's indexed objects, keyed by profile_id. A mutable bucket
  # (recorders append to the collections), so a class; still JSON-serializable.
  class ProfileRegistryEntry
    include JSON::Serializable

    property profile : Hash(String, JSON::Any) = {} of String => JSON::Any
    property goals : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any)
    property instructions : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any)
    property personality : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any)
    property preferences : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any)

    def initialize
    end

    def empty? : Bool
      profile.empty? && goals.empty? && instructions.empty? && personality.empty? && preferences.empty?
    end
  end

  class_property profile_registry = {} of String => ProfileRegistryEntry

  def self._get_or_create_profile_entry(profile_id : String) : ProfileRegistryEntry
    profile_registry[profile_id] ||= ProfileRegistryEntry.new
  end

  def self.clear_profile_registry : Nil
    self.profile_registry = {} of String => ProfileRegistryEntry
  end

  # The profile_id to use for auto-triggered requests: the configured
  # default, else the first registered profile, else nil.
  def self._get_default_profile_id(settings : AgentProfileSettings) : String?
    if (pid = settings.default_profile_id) && !pid.empty?
      return pid
    end
    profile_registry.keys.first?
  end

  # Repopulate the registry from objects already in `graph` (after a runtime
  # resume replays events without firing behaviors). Returns the number of
  # profile objects indexed.
  def self.rebuild_profile_registry(graph : Chronicle::GraphProjection) : Int32
    self.profile_registry = {} of String => ProfileRegistryEntry
    count = 0
    graph.objects(type: "agent_profile").each do |obj|
      _get_or_create_profile_entry(obj.id).profile =
        JSON.parse(obj.data).as_h.merge({"id" => JSON::Any.new(obj.id)})
      count += 1
    end
    count + _index_related(graph, "goal", :goals) +
      _index_related(graph, "standing_instruction", :instructions) +
      _index_related(graph, "personality_profile", :personality) +
      _index_related(graph, "owner_preference", :preferences)
  end

  # Index objects of one related type into their profile's bucket.
  private def self._index_related(graph : Chronicle::GraphProjection, object_type : String, bucket : Symbol) : Int32
    count = 0
    graph.objects(type: object_type).each do |obj|
      data = JSON.parse(obj.data).as_h
      profile_id = data["profile_id"]?.try(&.as_s?)
      next if profile_id.nil? || profile_id.empty?

      entry = _get_or_create_profile_entry(profile_id)
      with_data = data.merge({"id" => JSON::Any.new(obj.id)})
      case bucket
      when :goals        then entry.goals << with_data
      when :instructions then entry.instructions << with_data
      when :personality  then entry.personality << with_data
      when :preferences  then entry.preferences << with_data
      end
      count += 1
    end
    count
  end

  # ------------------------------------------------------------------ context assembly

  # Goal priority rank for sorting (critical first). Nested module so the
  # DSL's `pack` macro (which assumes every direct constant is a type)
  # doesn't trip over the map constant.
  module GoalPriorities
    ORDER = {"critical" => 0, "high" => 1, "medium" => 2, "low" => 3}
  end

  # Assemble a ProfileContextView from already-fetched profile inputs.
  # Pure function — no graph I/O. Shared by the provider behavior and the
  # direct assemble_profile_view path so both produce identical context.
  def self.build_profile_context_view(
    profile_id : String,
    profile_data : Hash(String, JSON::Any),
    registry_entry : ProfileRegistryEntry,
    settings : AgentProfileSettings,
    channel : String?,
    audience_role : String?,
    include_goals : Bool,
    include_preferences : Bool,
    frame_id : String? = nil,
    request_id : String? = nil,
  ) : ProfileContextView
    is_external = audience_role.nil? || audience_role.in?({"external", "customer", "unknown"})

    agent_name = profile_data["name"]?.try(&.as_s?) || settings.default_agent_name
    mission = profile_data["mission"]?.try(&.as_s?) || settings.default_mission
    mission = "" if is_external && !settings.expose_mission_to_external?

    personality = _matched_personality(registry_entry, channel, audience_role, settings)

    # --- Goals (active, sorted by priority, limited) ---
    active_goals = [] of Hash(String, JSON::Any)
    if include_goals
      active = registry_entry.goals.select { |goal| goal["status"]?.try(&.as_s?) == "active" }
      active.sort_by! { |goal| GoalPriorities::ORDER[goal["priority"]?.try(&.as_s?) || "medium"]? || 2 }
      active_goals = active.first(settings.max_active_goals)
    end

    instruction_texts = _matched_instructions(registry_entry, channel, audience_role, settings)
    owner_prefs = _matched_preferences(registry_entry, channel, include_preferences)

    ProfileContextView.new(
      profile_id: profile_id,
      channel: channel,
      audience_role: audience_role,
      agent_name: agent_name,
      mission: mission,
      personality: personality,
      active_goals: active_goals,
      standing_instructions: instruction_texts,
      owner_preferences: owner_prefs,
      request_id: request_id,
      frame_id: frame_id,
      metadata: {"assembled_by" => JSON::Any.new("profile_context_provider")},
    )
  end

  # First personality profile matching channel + audience_role, else the
  # settings defaults.
  def self._matched_personality(
    registry_entry : ProfileRegistryEntry,
    channel : String?,
    audience_role : String?,
    settings : AgentProfileSettings,
  ) : Hash(String, String)
    personality = {"tone" => settings.default_tone, "verbosity" => settings.default_verbosity, "formality" => settings.default_formality}
    registry_entry.personality.each do |personality_entry|
      p_channel = personality_entry["applies_to_channel"]?.try(&.as_s?)
      p_role = personality_entry["applies_to_audience_role"]?.try(&.as_s?)
      if (p_channel.nil? || p_channel == channel) && (p_role.nil? || p_role == audience_role)
        personality = {
          "tone"      => personality_entry["tone"]?.try(&.as_s?) || settings.default_tone,
          "verbosity" => personality_entry["verbosity"]?.try(&.as_s?) || settings.default_verbosity,
          "formality" => personality_entry["formality"]?.try(&.as_s?) || settings.default_formality,
        }
        break
      end
    end
    personality
  end

  # Active, channel/audience-matched instructions sorted by priority desc.
  def self._matched_instructions(
    registry_entry : ProfileRegistryEntry,
    channel : String?,
    audience_role : String?,
    settings : AgentProfileSettings,
  ) : Array(String)
    matched = [] of Hash(String, JSON::Any)
    registry_entry.instructions.each do |instruction|
      next if (instruction["active"]?.try(&.as_bool?)) == false

      i_channel = instruction["applies_to_channel"]?.try(&.as_s?)
      i_role = instruction["applies_to_audience_role"]?.try(&.as_s?)
      if (i_channel.nil? || i_channel == channel) && (i_role.nil? || i_role == audience_role)
        matched << instruction
      end
    end
    matched.sort_by! { |instruction| -(instruction["priority"]?.try(&.as_i) || 50) }
    matched.first(settings.max_standing_instructions).map { |instruction| instruction["text"]?.try(&.as_s?) || "" }
  end

  # Channel-matched owner preferences.
  def self._matched_preferences(
    registry_entry : ProfileRegistryEntry,
    channel : String?,
    include_preferences : Bool,
  ) : Hash(String, String)
    prefs = {} of String => String
    return prefs if !include_preferences

    registry_entry.preferences.each do |preference|
      p_channel = preference["channel"]?.try(&.as_s?)
      if p_channel.nil? || p_channel == channel
        prefs[preference["key"]?.try(&.as_s?) || ""] = preference["value"]?.try(&.as_s?) || ""
      end
    end
    prefs
  end

  # Assemble a ProfileContextView directly, without writing it to the graph.
  # Used by other packs that need profile context inline. Returns nil when
  # no profile is available.
  def self.assemble_profile_view(
    graph : Chronicle::GraphProjection,
    settings : AgentProfileSettings? = nil,
    profile_id : String? = nil,
    channel : String? = nil,
    audience_role : String? = nil,
    include_goals : Bool = true,
    include_preferences : Bool = true,
    frame_id : String? = nil,
    request_id : String? = nil,
  ) : ProfileContextView?
    s = settings || AgentProfileSettings.from_json("{}")
    pid = profile_id || _get_default_profile_id(s)
    return nil if pid.nil?

    profile_data = {} of String => JSON::Any
    begin
      if profile_obj = graph.get_object(pid)
        profile_data = JSON.parse(profile_obj.data).as_h
      end
    rescue
    end
    registry_entry = profile_registry[pid]? || ProfileRegistryEntry.new
    profile_data = registry_entry.profile if profile_data.empty?

    return nil if profile_data.empty? && registry_entry.empty?

    build_profile_context_view(
      profile_id: pid, profile_data: profile_data, registry_entry: registry_entry,
      settings: s, channel: channel, audience_role: audience_role,
      include_goals: include_goals, include_preferences: include_preferences,
      frame_id: frame_id, request_id: request_id,
    )
  end

  # ------------------------------------------------------------------ behaviors

  # Index an AgentProfile in the local registry.
  @[Chronicle::Packs::Annotations::Behavior(name: "profile_registry_recorder", on: ["object.created"], where: {"type" => "agent_profile"})]
  def profile_registry_recorder(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : AgentProfileSettings) : Nil
    payload = JSON.parse(event.payload)
    profile_id = payload["id"]?.try(&.as_s?)
    return if profile_id.nil?

    data = payload["data"]?
    entry = _get_or_create_profile_entry(profile_id)
    entry.profile = (data.try(&.as_h) || {} of String => JSON::Any).merge({"id" => JSON::Any.new(profile_id)})
  end

  # Index a Goal in the profile registry.
  @[Chronicle::Packs::Annotations::Behavior(name: "goal_registry_recorder", on: ["object.created"], where: {"type" => "goal"})]
  def goal_registry_recorder(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : AgentProfileSettings) : Nil
    payload = JSON.parse(event.payload)
    goal_id = payload["id"]?.try(&.as_s?)
    return if goal_id.nil?

    data = payload["data"]?
    return if data.nil?

    profile_id = data["profile_id"]?.try(&.as_s?) || ""
    return if profile_id.empty?

    _get_or_create_profile_entry(profile_id).goals << data.as_h.merge({"id" => JSON::Any.new(goal_id)})
  end

  # Index a StandingInstruction in the profile registry.
  @[Chronicle::Packs::Annotations::Behavior(name: "instruction_registry_recorder", on: ["object.created"], where: {"type" => "standing_instruction"})]
  def instruction_registry_recorder(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : AgentProfileSettings) : Nil
    payload = JSON.parse(event.payload)
    instr_id = payload["id"]?.try(&.as_s?)
    return if instr_id.nil?

    data = payload["data"]?
    return if data.nil?

    profile_id = data["profile_id"]?.try(&.as_s?) || ""
    return if profile_id.empty?

    _get_or_create_profile_entry(profile_id).instructions << data.as_h.merge({"id" => JSON::Any.new(instr_id)})
  end

  # Index a PersonalityProfile in the profile registry.
  @[Chronicle::Packs::Annotations::Behavior(name: "personality_registry_recorder", on: ["object.created"], where: {"type" => "personality_profile"})]
  def personality_registry_recorder(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : AgentProfileSettings) : Nil
    payload = JSON.parse(event.payload)
    obj_id = payload["id"]?.try(&.as_s?)
    return if obj_id.nil?

    data = payload["data"]?
    return if data.nil?

    profile_id = data["profile_id"]?.try(&.as_s?) || ""
    return if profile_id.empty?

    _get_or_create_profile_entry(profile_id).personality << data.as_h.merge({"id" => JSON::Any.new(obj_id)})
  end

  # Index an OwnerPreference in the profile registry.
  @[Chronicle::Packs::Annotations::Behavior(name: "preference_registry_recorder", on: ["object.created"], where: {"type" => "owner_preference"})]
  def preference_registry_recorder(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : AgentProfileSettings) : Nil
    payload = JSON.parse(event.payload)
    obj_id = payload["id"]?.try(&.as_s?)
    return if obj_id.nil?

    data = payload["data"]?
    return if data.nil?

    profile_id = data["profile_id"]?.try(&.as_s?) || ""
    return if profile_id.empty?

    _get_or_create_profile_entry(profile_id).preferences << data.as_h.merge({"id" => JSON::Any.new(obj_id)})
  end

  # Auto-create a ProfileContextRequest when an AuthContext arrives.
  @[Chronicle::Packs::Annotations::Behavior(name: "profile_context_trigger", on: ["object.created"], where: {"type" => "auth_context"}, creates: ["profile_context_request"])]
  def profile_context_trigger(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : AgentProfileSettings) : Nil
    return if !settings.auto_trigger_on_auth_context?

    profile_id = _get_default_profile_id(settings)
    return if profile_id.nil?

    payload = JSON.parse(event.payload)
    auth_ctx_id = payload["id"]?.try(&.as_s?)
    return if auth_ctx_id.nil?

    data = payload["data"]?
    channel = data.try(&.["channel"]?.try(&.as_s?)) || "unknown"
    principal_role = data.try(&.["principal_role"]?.try(&.as_s?)) || "unknown"
    frame_id = data.try(&.["frame_id"]?.try(&.as_s?))

    request_data = JSON.build do |json|
      json.object do
        json.field "profile_id", profile_id
        json.field "channel", channel
        json.field "audience_role", principal_role
        json.field "include_goals", true
        json.field "include_preferences", principal_role.in?({"owner", "admin"})
        json.field "frame_id", frame_id if frame_id
        json.field "metadata", {"triggered_by" => JSON::Any.new("auth_context"), "auth_context_id" => JSON::Any.new(auth_ctx_id)}
      end
    end
    request = graph.add_object("profile_context_request", request_data)

    begin
      graph.add_relation(auth_ctx_id, request.id, "triggers_context_for")
    rescue
    end
  end

  # Auto-create a ProfileContextRequest when a Frame is opened.
  @[Chronicle::Packs::Annotations::Behavior(name: "frame_context_trigger", on: ["object.created"], where: {"type" => "frame"}, creates: ["profile_context_request"])]
  def frame_context_trigger(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : AgentProfileSettings) : Nil
    return if !settings.auto_trigger_on_frame?

    profile_id = _get_default_profile_id(settings)
    return if profile_id.nil?

    payload = JSON.parse(event.payload)
    frame_id = payload["id"]?.try(&.as_s?)
    return if frame_id.nil?

    data = payload["data"]?
    channel = data.try(&.["channel"]?.try(&.as_s?)) || "unknown"
    audience_role = data.try(&.["audience_role"]?.try(&.as_s?)) || "owner"

    request_data = JSON.build do |json|
      json.object do
        json.field "profile_id", profile_id
        json.field "channel", channel
        json.field "audience_role", audience_role
        json.field "include_goals", true
        json.field "include_preferences", true
        json.field "frame_id", frame_id
        json.field "metadata", {"triggered_by" => JSON::Any.new("frame"), "frame_id" => JSON::Any.new(frame_id)}
      end
    end
    request = graph.add_object("profile_context_request", request_data)

    begin
      graph.add_relation(frame_id, request.id, "triggers_context_for")
    rescue
    end
  end

  # Assemble a scoped ProfileContextView from a ProfileContextRequest.
  @[Chronicle::Packs::Annotations::Behavior(name: "profile_context_provider", on: ["object.created"], where: {"type" => "profile_context_request"}, creates: ["profile_context_view"])]
  def profile_context_provider(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : AgentProfileSettings) : Nil
    payload = JSON.parse(event.payload)
    request_id = payload["id"]?.try(&.as_s?)
    return if request_id.nil?

    data = payload["data"]?
    return if data.nil?

    profile_id = data["profile_id"]?.try(&.as_s?) || ""
    return if profile_id.empty?

    channel = data["channel"]?.try(&.as_s?)
    audience_role = data["audience_role"]?.try(&.as_s?)
    include_goals = data["include_goals"]?.try(&.as_bool?) != false
    include_preferences = data["include_preferences"]?.try(&.as_bool?) != false
    frame_id = data["frame_id"]?.try(&.as_s?)

    profile_data = {} of String => JSON::Any
    begin
      if profile_obj = graph.get_object(profile_id)
        profile_data = JSON.parse(profile_obj.data).as_h
      end
    rescue
    end
    registry_entry = profile_registry[profile_id]? || ProfileRegistryEntry.new
    profile_data = registry_entry.profile if profile_data.empty?

    view_model = build_profile_context_view(
      profile_id: profile_id, profile_data: profile_data, registry_entry: registry_entry,
      settings: settings, channel: channel, audience_role: audience_role,
      include_goals: include_goals, include_preferences: include_preferences,
      frame_id: frame_id, request_id: request_id,
    )
    view = graph.add_object("profile_context_view", view_model.to_json)

    begin
      graph.add_relation(request_id, view.id, "fulfilled_by_profile")
    rescue
    end
  end
end
