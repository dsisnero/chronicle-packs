require "json"

module Chronicle::Packs::Codebase
  # Codebase Pack tools. Ported from upstream packs/codebase/tools.py.
  #
  # The `*_fn` functions are the ported behavior and take the graph
  # explicitly. The declared Chronicle::Tool wrappers read a graph bound by
  # the host via `bound_graph` (chronicle's Tool model is args-only).

  # The graph the declared tools operate on.
  class_property bound_graph : Chronicle::GraphProjection? = nil

  # Create a source from a GitHub webhook payload, triggering codebase behaviors.
  def self.ingest_github_webhook_fn(
    graph : Chronicle::GraphProjection,
    event : String,
    payload : Hash(String, JSON::Any),
  ) : Chronicle::GraphObject
    content = payload.to_s[0, 2000]
    metadata = payload.dup
    metadata["event"] = JSON::Any.new(event)
    graph.add_object("source", {
      "kind"     => JSON::Any.new("github_webhook"),
      "content"  => JSON::Any.new(content),
      "channel"  => JSON::Any.new("github"),
      "metadata" => JSON::Any.new(metadata),
    }.to_json, actor: "codebase")
  end

  # Create a source for a repo file, triggering adr_extractor if applicable.
  def self.ingest_repo_file_fn(
    graph : Chronicle::GraphProjection,
    repo_full_name : String,
    path : String = "",
    content : String = "",
    language : String? = nil,
  ) : Chronicle::GraphObject
    graph.add_object("source", {
      "kind"     => JSON::Any.new("repo_file"),
      "content"  => JSON::Any.new(content),
      "channel"  => JSON::Any.new("github"),
      "metadata" => JSON::Any.new({
        "repo_full_name" => JSON::Any.new(repo_full_name),
        "path"           => JSON::Any.new(path),
        "language"       => JSON::Any.new(language),
        "repository"     => JSON::Any.new({"full_name" => JSON::Any.new(repo_full_name)}),
      }),
    }.to_json, actor: "codebase")
  end

  # Create a Repo source object (repo_manifest) to trigger repo_ingester.
  def self.create_repo_fn(
    graph : Chronicle::GraphProjection,
    full_name : String,
    description : String = "",
    language : String? = nil,
    url : String? = nil,
    dependencies : Array(Hash(String, JSON::Any))? = nil,
  ) : Chronicle::GraphObject
    graph.add_object("source", {
      "kind"     => JSON::Any.new("repo_manifest"),
      "content"  => JSON::Any.new(description),
      "channel"  => JSON::Any.new("github"),
      "metadata" => JSON::Any.new({
        "full_name"  => JSON::Any.new(full_name),
        "repository" => JSON::Any.new({
          "full_name"   => JSON::Any.new(full_name),
          "description" => JSON::Any.new(description),
          "language"    => JSON::Any.new(language),
          "html_url"    => JSON::Any.new(url || "https://github.com/#{full_name}"),
        }),
        "dependencies" => JSON::Any.new((dependencies || [] of Hash(String, JSON::Any)).map { |dep| JSON::Any.new(dep) }),
      }),
    }.to_json, actor: "codebase")
  end

  # Create a source for a GitHub issue.
  def self.create_issue_fn(
    graph : Chronicle::GraphProjection,
    repo_full_name : String,
    issue_number : Int32,
    title : String,
    body : String = "",
    state : String = "open",
    labels : Array(String)? = nil,
    author_ref : String? = nil,
  ) : Chronicle::GraphObject
    graph.add_object("source", {
      "kind"     => JSON::Any.new("issue"),
      "content"  => JSON::Any.new("#{title}\n\n#{body}"),
      "channel"  => JSON::Any.new("github"),
      "metadata" => JSON::Any.new({
        "event"          => JSON::Any.new("issues"),
        "repo_full_name" => JSON::Any.new(repo_full_name),
        "repository"     => JSON::Any.new({"full_name" => JSON::Any.new(repo_full_name)}),
        "number"         => JSON::Any.new(issue_number),
        "issue_number"   => JSON::Any.new(issue_number),
        "title"          => JSON::Any.new(title),
        "body"           => JSON::Any.new(body),
        "state"          => JSON::Any.new(state),
        "labels"         => JSON::Any.new((labels || [] of String).map { |label| JSON::Any.new({"name" => JSON::Any.new(label)}) }),
        "author_ref"     => JSON::Any.new(author_ref),
      }),
    }.to_json, actor: "codebase")
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "codebase tools require a bound graph (set Codebase.bound_graph)"
    )
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "ingest_github_webhook", description: "Ingest a GitHub webhook event payload.", deterministic: true)]
  def ingest_github_webhook_tool(args : String) : String
    input = JSON.parse(args).as_h
    payload = input["payload"]?.try(&.as_h?) || {} of String => JSON::Any
    result = ingest_github_webhook_fn(
      bound_graph_or_raise,
      input["event"]?.try(&.as_s?) || "",
      payload,
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "ingest_repo_file", description: "Ingest a repo file (e.g. ADR markdown) into the graph.", deterministic: true)]
  def ingest_repo_file_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = ingest_repo_file_fn(
      bound_graph_or_raise,
      input["repo_full_name"]?.try(&.as_s?) || "",
      path: input["path"]?.try(&.as_s?) || "",
      content: input["content"]?.try(&.as_s?) || "",
      language: input["language"]?.try(&.as_s?),
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "create_repo", description: "Create a repo manifest source to trigger repo ingestion.", deterministic: true)]
  def create_repo_tool(args : String) : String
    input = JSON.parse(args).as_h
    deps = input["dependencies"]?.try(&.as_a?) || [] of JSON::Any
    result = create_repo_fn(
      bound_graph_or_raise,
      input["full_name"]?.try(&.as_s?) || "",
      description: input["description"]?.try(&.as_s?) || "",
      language: input["language"]?.try(&.as_s?),
      url: input["url"]?.try(&.as_s?),
      dependencies: deps.map(&.as_h),
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "create_issue", description: "Create an issue source to trigger issue_tracker.", deterministic: true)]
  def create_issue_tool(args : String) : String
    input = JSON.parse(args).as_h
    labels = input["labels"]?.try(&.as_a?) || [] of JSON::Any
    result = create_issue_fn(
      bound_graph_or_raise,
      input["repo_full_name"]?.try(&.as_s?) || "",
      input["issue_number"]?.try(&.as_i?) || 0,
      input["title"]?.try(&.as_s?) || "",
      body: input["body"]?.try(&.as_s?) || "",
      state: input["state"]?.try(&.as_s?) || "open",
      labels: labels.map(&.as_s),
      author_ref: input["author_ref"]?.try(&.as_s?),
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end
end
