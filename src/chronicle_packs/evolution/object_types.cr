require "json"

module Chronicle::Packs::Evolution
  # Evolution Pack object types. Ported from upstream
  # packs/evolution/object_types.py.
  #
  # The loop: capability_gap → mod_proposal → gate_result → mod_trial →
  # mod_promotion → adoption_ticket. Every transition is graph state; the
  # bundle hash pins what was reviewed to what loads.

  # Something the assistant could not do.
  @[Chronicle::Packs::Annotations::ObjectType(name: "capability_gap", description: "A detected capability gap (evolution loop stage 0).")]
  struct CapabilityGap
    include JSON::Serializable

    getter kind : String
    getter description : String = ""
    getter evidence_refs : Array(String) = [] of String
    # Deterministically inherited taint (design §3 stage 0).
    getter injection_flags : Array(String) = [] of String
    getter status : String = "open"
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # What an author READ before it wrote (llm-author-design §4).
  @[Chronicle::Packs::Annotations::ObjectType(name: "drafting_context", description: "What an author read before it wrote: origins, charter hash, deterministic taint union (llm-author-design §4).")]
  struct DraftingContext
    include JSON::Serializable

    getter charter_hash : String = ""
    getter gap_id : String = ""
    getter structured_fields : Array(String) = [] of String
    getter surface_sources : Array(String) = [] of String
    getter owner_input_ids : Array(String) = [] of String
    getter injection_flags : Array(String) = [] of String
    getter model : String = "scripted"
    getter day : String = ""
    getter at : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # One candidate pack version.
  @[Chronicle::Packs::Annotations::ObjectType(name: "mod_proposal", description: "A candidate agent-authored pack, pinned by bundle hash.")]
  struct ModProposal
    include JSON::Serializable

    getter gap_id : String = ""
    getter drafting_context_id : String = ""
    getter pack_name : String
    getter pack_version : String = "0.1.0"
    getter source_artifact_ids : Array(String) = [] of String
    # The §2 pin: manifest-spec §4 walk INCLUDING manifest.toml.
    getter bundle_hash : String = ""
    getter rationale : String = ""
    getter authored_by : String = "agent"
    getter injection_flags : Array(String) = [] of String
    getter status : String = "drafted"
    getter status_note : String = ""
    getter frame_id : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # One gate's verdict on one proposal.
  @[Chronicle::Packs::Annotations::ObjectType(name: "gate_result", description: "One gate's verdict on a proposal (audit-first).")]
  struct GateResult
    include JSON::Serializable

    getter proposal_id : String
    getter gate : String
    getter verdict : String
    getter details : String = ""
    getter at : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # One fork trial of one proposal.
  @[Chronicle::Packs::Annotations::ObjectType(name: "mod_trial", description: "A fork trial: run id, eval summary, diff, verdict.")]
  struct ModTrial
    include JSON::Serializable

    getter proposal_id : String
    getter fork_run_id : String = ""
    getter forked_at_event : String = ""
    getter eval_summary : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter diff_summary : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter failures : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any)
    getter verdict : String = ""
    getter at : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A pack adoption, recorded AT LOAD TIME.
  @[Chronicle::Packs::Annotations::ObjectType(name: "mod_promotion", description: "An adoption record, created at load time, the durable registry boot re-loads from.")]
  struct ModPromotion
    include JSON::Serializable

    getter proposal_id : String
    getter trial_id : String = ""
    getter pack_name : String = ""
    getter fork_run_id : String = ""
    getter promote_marker_event_id : String = ""
    getter applied_counts : Hash(String, JSON::Any) = {} of String => JSON::Any
    getter bundle_hash : String = ""
    getter status : String = "loading"
    getter at : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # A disable/rollback action.
  @[Chronicle::Packs::Annotations::ObjectType(name: "mod_rollback", description: "A disable/rollback action.")]
  struct ModRollback
    include JSON::Serializable

    getter promotion_id : String
    getter method : String = "disable_pack"
    getter reason : String = ""
    getter at : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end

  # Phase-one output of the governed adoption/disable capabilities.
  @[Chronicle::Packs::Annotations::ObjectType(name: "adoption_ticket", description: "Governed phase-one request the chassis executes out-of-frame.")]
  struct AdoptionTicket
    include JSON::Serializable

    getter kind : String = "adopt"
    getter proposal_id : String = ""
    getter promotion_id : String = ""
    getter call_id : String = ""
    getter reason : String = ""
    getter status : String = "open"
    getter status_note : String = ""
    getter at : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end
end
