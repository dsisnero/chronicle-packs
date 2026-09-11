require "json"

module Chronicle::Packs::ConnectorControl
  # Stable connector-family native-shape contracts (ADRs 0033–0034).
  # Ported from upstream packs/connector_control/contracts.py. Families are
  # modeled as plain String; the family models are JSON::Serializable structs
  # used to validate/canonicalize native payloads.

  # One conversation thread summary.
  struct ConversationThreadSummary
    include JSON::Serializable

    getter thread_ref : String
    getter title : String = ""
    getter participant_refs : Array(String) = [] of String
    getter last_message_at : String?
    getter unread_count : Int32 = 0
    getter message_count : Int32 = 0
    getter latest_message_ref : String?
    getter latest_sender : String?
    getter preview : String = ""
    getter interpretation_state : String = "empty"
    getter status : String = "open"
    getter refs : Array(String) = [] of String
  end

  struct ConversationNativeData
    include JSON::Serializable

    getter threads : Array(ConversationThreadSummary) = [] of ConversationThreadSummary
    getter total_count : Int32 = 0
  end

  # One agenda occurrence.
  struct AgendaOccurrence
    include JSON::Serializable

    getter occurrence_ref : String
    getter title : String = ""
    getter start : String?
    getter end : String?
    getter timezone : String?
    getter status : String = "confirmed"
    getter participant_refs : Array(String) = [] of String
    getter refs : Array(String) = [] of String
  end

  struct AgendaNativeData
    include JSON::Serializable

    getter occurrences : Array(AgendaOccurrence) = [] of AgendaOccurrence
    getter window_start : String?
    getter window_end : String?
    getter total_count : Int32 = 0
  end

  struct RecordColumn
    include JSON::Serializable

    getter key : String
    getter label : String
  end

  struct RecordsNativeData
    include JSON::Serializable

    getter columns : Array(RecordColumn) = [] of RecordColumn
    getter rows : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any)
    getter total_count : Int32 = 0
  end

  # One library item.
  struct LibraryItem
    include JSON::Serializable

    getter item_ref : String
    getter title : String = ""
    getter kind : String = "document"
    getter parent_ref : String?
    getter revision_ref : String?
    getter updated_at : String?
    getter refs : Array(String) = [] of String
  end

  struct LibraryNativeData
    include JSON::Serializable

    getter items : Array(LibraryItem) = [] of LibraryItem
    getter total_count : Int32 = 0
  end

  struct TelemetryPoint
    include JSON::Serializable

    getter bucket : String
    getter label : String = ""
    getter value : Float64
    getter refs : Array(String) = [] of String
  end

  struct TelemetryNativeData
    include JSON::Serializable

    getter points : Array(TelemetryPoint) = [] of TelemetryPoint
    getter unit : String = "count"
  end

  # Canonicalize a parsed native model back to a plain object hash.
  private def self._canonicalize(raw_json : String) : Hash(String, JSON::Any)
    JSON.parse(raw_json).as_h
  end

  # Python's family models use Pydantic `extra="forbid"`. Crystal's
  # JSON::Serializable deliberately ignores unknown object keys, so enforce
  # the same closed root shapes before deserializing rather than silently
  # admitting provider payloads into a native view.
  private def self._forbid_unknown_keys!(family : String, data : Hash(String, JSON::Any), allowed : Array(String)) : Nil
    data.each_key do |key|
      unless allowed.includes?(key)
        raise ArgumentError.new("unknown #{family} native data field #{key.inspect}")
      end
    end
  end

  # Validate and canonicalize one family-native payload.
  def self.validate_native_data(family : String, data : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
    case family
    when "conversation"
      _forbid_unknown_keys!(family, data, ["threads", "total_count"])
      _canonicalize(ConversationNativeData.from_json(JSON::Any.new(data).to_json).to_json)
    when "schedule"
      _forbid_unknown_keys!(family, data, ["occurrences", "window_start", "window_end", "total_count"])
      _canonicalize(AgendaNativeData.from_json(JSON::Any.new(data).to_json).to_json)
    when "records"
      _forbid_unknown_keys!(family, data, ["columns", "rows", "total_count"])
      _canonicalize(RecordsNativeData.from_json(JSON::Any.new(data).to_json).to_json)
    when "documents"
      _forbid_unknown_keys!(family, data, ["items", "total_count"])
      _canonicalize(LibraryNativeData.from_json(JSON::Any.new(data).to_json).to_json)
    when "telemetry"
      _forbid_unknown_keys!(family, data, ["points", "unit"])
      _canonicalize(TelemetryNativeData.from_json(JSON::Any.new(data).to_json).to_json)
    else
      raise ArgumentError.new("unknown connector family #{family.inspect}")
    end
  end
end
