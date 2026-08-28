require "json"

module Chronicle::Packs::Research
  # Research Pack tools. Ported from upstream packs/research/tools.py.
  #
  # The `*_fn` functions are the ported behavior and take the graph
  # explicitly. The declared Chronicle::Tool wrappers read a graph bound by
  # the host via `bound_graph` (chronicle's Tool model is args-only).

  # The graph the declared tools operate on.
  class_property bound_graph : Chronicle::GraphProjection? = nil

  # Create a source object for a research paper, triggering paper_ingester.
  def self.ingest_research_paper_fn(
    graph : Chronicle::GraphProjection,
    title : String,
    abstract_text : String = "",
    authors : String = "",
    venue : String = "",
    year : Int32? = nil,
    doi : String? = nil,
    arxiv_id : String? = nil,
    keywords : Array(String)? = nil,
  ) : Chronicle::GraphObject
    graph.add_object("source", {
      "kind"     => JSON::Any.new("research_paper"),
      "content"  => JSON::Any.new(abstract_text),
      "channel"  => JSON::Any.new("research"),
      "metadata" => JSON::Any.new({
        "title"    => JSON::Any.new(title),
        "abstract" => JSON::Any.new(abstract_text),
        "authors"  => JSON::Any.new(authors),
        "venue"    => JSON::Any.new(venue),
        "year"     => JSON::Any.new(year),
        "doi"      => JSON::Any.new(doi),
        "arxiv_id" => JSON::Any.new(arxiv_id),
        "keywords" => JSON::Any.new((keywords || [] of String).map { |k| JSON::Any.new(k) }),
      }),
    }.to_json, actor: "research")
  end

  # Directly create an IdeaAtom, triggering hypothesis_generator and
  # research_direction_synthesizer.
  def self.create_idea_atom_fn(
    graph : Chronicle::GraphProjection,
    text : String,
    source_paper_ids : Array(String)? = nil,
    tags : Array(String)? = nil,
    novelty_score : Float64 = 0.6,
    coherence_score : Float64 = 0.6,
  ) : Chronicle::GraphObject
    graph.add_object("idea_atom", IdeaAtom.new(
      text: text,
      source_paper_ids: source_paper_ids || [] of String,
      tags: tags || [] of String,
      novelty_score: novelty_score,
      coherence_score: coherence_score,
    ).to_json, actor: "research")
  end

  # Create a research Experiment linked to a direction.
  def self.create_experiment_fn(
    graph : Chronicle::GraphProjection,
    title : String,
    hypothesis : String = "",
    direction_id : String? = nil,
  ) : Chronicle::GraphObject
    exp = graph.add_object("experiment", Experiment.new(
      title: title,
      hypothesis: hypothesis,
      direction_id: direction_id,
      status: ExperimentStatus::Proposed,
    ).to_json, actor: "research")
    if direction_id
      begin
        graph.add_relation(exp.id, direction_id, "tests_direction", actor: "research")
      rescue
      end
    end
    exp
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "research tools require a bound graph (set Research.bound_graph)"
    )
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "ingest_research_paper", description: "Ingest a research paper into the graph.", deterministic: true)]
  def ingest_research_paper_tool(args : String) : String
    input = JSON.parse(args).as_h
    year = input["year"]?.try(&.as_i?)
    kws = input["keywords"]?.try(&.as_a?)
    result = ingest_research_paper_fn(
      bound_graph_or_raise,
      input["title"]?.try(&.as_s?) || "",
      abstract_text: input["abstract"]?.try(&.as_s?) || "",
      authors: input["authors"]?.try(&.as_s?) || "",
      venue: input["venue"]?.try(&.as_s?) || "",
      year: year,
      doi: input["doi"]?.try(&.as_s?),
      arxiv_id: input["arxiv_id"]?.try(&.as_s?),
      keywords: kws.try { |arr| arr.map(&.as_s) },
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "create_idea_atom", description: "Create an IdeaAtom from a research insight.", deterministic: true)]
  def create_idea_atom_tool(args : String) : String
    input = JSON.parse(args).as_h
    paper_ids = input["source_paper_ids"]?.try(&.as_a?)
    tag_list = input["tags"]?.try(&.as_a?)
    result = create_idea_atom_fn(
      bound_graph_or_raise,
      input["text"]?.try(&.as_s?) || "",
      source_paper_ids: paper_ids.try { |arr| arr.map(&.as_s) },
      tags: tag_list.try { |arr| arr.map(&.as_s) },
      novelty_score: input["novelty_score"]?.try(&.as_f?) || 0.6,
      coherence_score: input["coherence_score"]?.try(&.as_f?) || 0.6,
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "create_experiment", description: "Create a research experiment linked to a direction.", deterministic: true)]
  def create_experiment_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = create_experiment_fn(
      bound_graph_or_raise,
      input["title"]?.try(&.as_s?) || "",
      hypothesis: input["hypothesis"]?.try(&.as_s?) || "",
      direction_id: input["direction_id"]?.try(&.as_s?),
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end
end
