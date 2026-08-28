require "json"

module Chronicle::Packs::Template
  # Object and relation types for the template pack. Ported from upstream
  # packs/_template/object_types.py. Replace with your pack's actual types.

  # Replace with your actual object schema.
  @[Chronicle::Packs::Annotations::ObjectType(name: "example_object", description: "Replace with a description of this object type.")]
  struct ExampleObject
    include JSON::Serializable

    getter name : String
    getter description : String = ""
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  end
end
