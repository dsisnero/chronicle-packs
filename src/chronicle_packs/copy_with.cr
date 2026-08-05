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
  #   define_copy_with(x, visible)
  # end
  # ```
  module CopyWith
    macro define_copy_with(*fields)
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
    end
  end
end
