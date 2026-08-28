require "json"

module Chronicle::Packs::Communication
  # Settings for the Communication Pack. Ported from upstream
  # packs/communication/settings.py (CommunicationSettings). Controls intent
  # detection, thread tracking, and response dispatch.
  struct CommunicationSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter intent_detection_mode : String = "heuristic"
    getter? auto_create_threads : Bool = true
    getter default_channel : String = "chat"
    getter low_confidence_intent_threshold : Float64 = 0.5
    # Deterministic intent -> Tool Gateway routing. Empty (default) = no
    # routing; intents stay informational. An open-shaped nested map, so it
    # stays a raw Hash rather than a typed record.
    getter intent_routes : Hash(String, Hash(String, JSON::Any)) = {} of String => Hash(String, JSON::Any)
    getter intent_route_min_confidence : Float64 = 0.6
    getter? auto_dispatch_approved_responses : Bool = true
    getter max_thread_participants : Int32 = 50
  end
end
