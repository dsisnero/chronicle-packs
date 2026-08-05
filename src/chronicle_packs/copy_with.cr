module Chronicle::Packs
  # Generates a `copy_with` for immutable structs: named params per field
  # defaulting to the current ivar value, returning a new instance through
  # the struct's explicit initializer. Prefer this over `record` when a
  # struct carries bool fields (`getter?` stays ameba-clean).
  #
  # ```
  # struct Point
  #   include Chronicle::Packs::CopyWith
  #   getter x : Int32
  #   getter? visible : Bool
  #
  #   def initialize(@x : Int32, @visible : Bool = false)
  #   end
  #
  #   define_copy_with
  # end
  # ```
  #
  # Call `define_copy_with` with no arguments to derive the field list from
  # the struct's instance variables (the initializer must accept every ivar
  # as a named arg). A explicit list (`define_copy_with(x, visible)`) still
  # works for structs whose initializer takes a subset. A `nil` value passed
  # explicitly is treated as "not provided" (keep the current ivar).
  module CopyWith
    macro define_copy_with(*fields)
      {% if fields.empty? %}
        def copy_with(**opts : **T) forall T
          {% verbatim do %}
            {% begin %}
              {% for ivar in @type.instance_vars %}
                {{ivar.id}} = (v = opts[:{{ivar.id}}]?).nil? ? @{{ivar.id}} : v.as({{ivar.type}})
              {% end %}
              {{@type}}.new(
                {% for ivar in @type.instance_vars %}
                  {{ivar.id}}: {{ivar.id}},
                {% end %}
              )
            {% end %}
          {% end %}
        end
      {% else %}
        def copy_with(
          {% for field in fields %}
            {{field.id}} = @{{field.id}},
          {% end %}
        )
          {{@type}}.new(
            {% for field in fields %}
              {{field.id}}: {{field.id}},
            {% end %}
          )
        end
      {% end %}
    end
  end
end
