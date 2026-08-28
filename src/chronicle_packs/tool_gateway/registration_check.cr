require "json"

module Chronicle::Packs::ToolGateway
  # Gateway-side registration enforcement (the Q8 chain, step 3). Ported
  # from upstream packs/tool_gateway/registration_check.py. At
  # register_local_capability time, an ARMED gateway resolves the
  # registering capability against graph-derived pack.loaded declarations
  # and refuses undeclared pairs, risk-class drift, action-class drift, and
  # registrations claiming a disabled pack's surface.

  class_property enforcement_graph : Chronicle::GraphProjection? = nil
  class_property enforcement_store : Chronicle::EventStore? = nil

  # Runtime pack lifecycle events are durable events owned by Runtime#store.
  # GraphProjection#events contains only events emitted through the projection,
  # so callers that arm after Runtime#load_pack must provide that store.
  def self.arm_registration_enforcement(graph : Chronicle::GraphProjection, store : Chronicle::EventStore? = nil) : Nil
    self.enforcement_graph = graph
    self.enforcement_store = store
  end

  def self.disarm_registration_enforcement : Nil
    self.enforcement_graph = nil
    self.enforcement_store = nil
  end

  # {pack_name: {"disabled": Bool, "capabilities": {pair => {risk, action}}}}
  # derived from pack.loaded / pack.disabled events, latest event wins.
  def self._pack_states(graph : Chronicle::GraphProjection) : Hash(String, {Bool, Hash({String, String}, {String, String})})
    events = enforcement_store.try(&.iter_events) || graph.events
    states = {} of String => {Bool, Hash({String, String}, {String, String})}
    events.each do |event|
      if event.type == "pack.loaded"
        payload = JSON.parse(event.payload).as_h
        name = payload["name"]?.try(&.as_s?) || ""
        caps = {} of {String, String} => {String, String}
        (payload["capabilities"]?.try(&.as_a) || [] of JSON::Any).each do |capability_ref|
          cdata = capability_ref.as_h
          provider = cdata["provider"]?.try(&.as_s?) || ""
          capability = cdata["capability"]?.try(&.as_s?) || ""
          risk = cdata["risk_class"]?.try(&.as_s?) || ""
          action = cdata["action_class"]?.try(&.as_s?) || ""
          caps[{provider, capability}] = {risk, action}
        end
        states[name] = {false, caps}
      elsif event.type == "pack.disabled"
        payload = JSON.parse(event.payload).as_h
        name = payload["name"]?.try(&.as_s?) || ""
        entry = states[name]? || {false, {} of {String, String} => {String, String}}
        states[name] = {true, entry[1]}
      end
    end
    states
  end

  # Raises when an armed graph refuses the registration. No-op when unarmed
  # or the origin is not native.
  def self.check_registration(provider_name : String, capability_name : String, risk_class : String, origin : String = "native", action_class : String = "") : Nil
    graph = enforcement_graph
    return if graph.nil? || origin != "native"

    pair = {provider_name, capability_name}
    key = "#{provider_name}.#{capability_name}"
    states = _pack_states(graph)
    declaring = states.select { |_name, state| state[1].has_key?(pair) }
    if declaring.empty?
      raise Chronicle::Packs::PackError.new("registration refused: no loaded pack declares capability #{key.inspect}. Declare it in the pack's Pack.capabilities so reviewers see it, or register before enforcement is armed for host-owned capabilities.")
    end
    enabled = declaring.select { |_name, state| !state[0] }
    if enabled.empty?
      names = declaring.keys.sort!.join(", ")
      raise Chronicle::Packs::PackError.new("registration refused: capability #{key.inspect} is declared only by disabled pack(s) (#{names}). Disable means disabled; re-enable is a fresh adoption, not a registry write.")
    end
    declared_risks = enabled.values.map { |state| state[1][pair][0] }.to_set
    unless declared_risks.includes?(risk_class)
      declared = declared_risks.to_a.sort.join(", ")
      raise Chronicle::Packs::PackError.new("registration refused: capability #{key.inspect} declared risk_class #{declared.inspect} but the registration call says #{risk_class.inspect}. Risk drift between the reviewed manifest and the live registry is exactly the swap the decision surface must not miss; fix the declaration or the call.")
    end
    declared_actions = enabled.values.map { |state| state[1][pair][1] }.to_set
    unless declared_actions.includes?(action_class)
      declared = declared_actions.to_a.sort.join(", ")
      raise Chronicle::Packs::PackError.new("registration refused: capability #{key.inspect} declared action_class #{declared.inspect} but the registration call says #{action_class.inspect}. Action-class drift between the reviewed manifest and the live registry changes authority; fix the declaration or the call.")
    end
  end
end
