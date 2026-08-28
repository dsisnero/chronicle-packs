module Chronicle::Packs::PublicPresence
  # Public presence relation types. Ported from upstream
  # packs/importers/public_presence/object_types.py (RELATION_TYPES).

  @[Chronicle::Packs::Annotations::RelationType(name: "bootstrap_call", source_types: ["presence_bootstrap_run"], target_types: ["capability_call"], description: "A bootstrap run proposed this gateway fetch call.")]
  struct BootstrapCall
  end
end
