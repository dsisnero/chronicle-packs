require "chronicle"

require "./settings"
require "./object_types"
require "./behaviors"

# Template Pack — the pack-authoring template: the canonical example of the
# scaffolding convention (settings, object_types, relation_types, behaviors,
# tools, fixtures). Replace with your pack's actual surface. Ported from
# upstream `packs/_template` (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
module Chronicle::Packs::Template
  include Chronicle::Packs::DSL

  pack(
    name: "template",
    version: "0.1.0",
    description: "Replace this with a one-sentence description of this pack.",
    settings_schema: TemplateSettings,
  )
end
