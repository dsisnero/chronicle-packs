require "json"
require "time"

module Chronicle::Packs::Codebase
  # Codebase Pack behaviors. Ported from upstream packs/codebase/behaviors.py.
  #
  # repo_ingester      — source.created (github_webhook/repo_file/repo_manifest)
  #                      → Repo
  # issue_tracker      — source.created (webhook event=issues or kind=issue)
  #                      → Issue + Core task
  # adr_extractor      — source.created (kind=repo_file, ADR path pattern)
  #                      → ArchitectureDecision
  # change_summarizer  — source.created (github_push/pull_request webhook)
  #                      → CodeChange
  # dependency_auditor — repo.created → Dependency objects from metadata
  #
  # Registries (class-level, cleared between fixtures via
  # clear_codebase_registry):
  #   repo_registry:  full_name → repo_id
  #   issue_registry: "full_name#number" → issue_id

  # File-extension → language map (upstream EXT_MAP). Nested so the DSL pack
  # macro does not treat it as an object type constant.
  module FileExtensionMap
    EXT_MAP = {
      ".py"   => "python",
      ".ts"   => "typescript",
      ".tsx"  => "typescript",
      ".js"   => "javascript",
      ".jsx"  => "javascript",
      ".go"   => "go",
      ".rs"   => "rust",
      ".java" => "java",
      ".cs"   => "csharp",
      ".rb"   => "ruby",
      ".php"  => "php",
      ".cpp"  => "cpp",
      ".c"    => "c",
      ".md"   => "markdown",
      ".yaml" => "yaml",
      ".yml"  => "yaml",
      ".json" => "json",
      ".toml" => "toml",
    }
  end

  # full_name → repo_id.
  class_property repo_registry = {} of String => String
  # "full_name#number" → issue_id.
  class_property issue_registry = {} of String => String

  # Reset all registries — call between test fixtures.
  def self.clear_codebase_registry : Nil
    self.repo_registry = {} of String => String
    self.issue_registry = {} of String => String
  end

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # Detect a language from a filename extension (upstream _detect_language).
  def self._detect_language(filename : String) : String?
    if filename.includes?(".")
      ext = "." + filename.rpartition(".").last.downcase
      FileExtensionMap::EXT_MAP[ext]?
    end
  end

  # True if the path matches an ADR path pattern (case-insensitive).
  def self._is_adr_path(path : String, patterns : Array(String)) : Bool
    path_lower = path.downcase
    patterns.any? { |pattern| path_lower.includes?(pattern.downcase) }
  end

  # Parse markdown ADR into context/decision/consequences sections.
  def self._parse_adr_content(content : String) : Hash(String, String)
    sections = {"context" => "", "decision" => "", "consequences" => ""}
    current : String? = nil
    content.split("\n").each do |line|
      lower = line.downcase.strip
      if lower.includes?("## context") || lower.includes?("## background")
        current = "context"
      elsif lower.includes?("## decision")
        current = "decision"
      elsif lower.includes?("## consequences") || lower.includes?("## result")
        current = "consequences"
      elsif current && !line.strip.empty?
        sections[current] += line + "\n"
      end
    end
    sections.transform_values(&.strip)
  end

  # Generate an incrementing ADR number per repo (upstream _mock_adr_number).
  def self._mock_adr_number(repo_id : String) : Int32
    count = issue_registry.count { |key, _value| key.starts_with?("adr:#{repo_id}:") }
    count + 1
  end

  # Ingest a repository source into a Repo object.
  @[Chronicle::Packs::Annotations::Behavior(name: "repo_ingester", on: ["object.created"], where: {"type" => "source"}, creates: ["repo"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream repo_ingester source-kind/registry branches
  def repo_ingester(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : CodebaseSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    source_id = payload["id"]?.try(&.as_s?)
    return if source_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    kind = data["kind"]?.try(&.as_s?) || ""
    return unless {"github_webhook", "repo_file", "repo_manifest"}.includes?(kind)

    meta = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    repo_data = meta["repository"]?.try(&.as_h?) || meta["repo"]?.try(&.as_h?) || {} of String => JSON::Any
    full_name = repo_data["full_name"]?.try(&.as_s?) || meta["full_name"]?.try(&.as_s?) || ""

    return if full_name.empty?
    return if repo_registry.has_key?(full_name)

    name = full_name.includes?("/") ? full_name.split("/").last : full_name
    language = repo_data["language"]?.try(&.as_s?) || meta["language"]?.try(&.as_s?)
    description = repo_data["description"]?.try(&.as_s?) || ""
    url = repo_data["html_url"]?.try(&.as_s?) || repo_data["url"]?.try(&.as_s?) || meta["url"]?.try(&.as_s?)
    stars = repo_data["stargazers_count"]?.try(&.as_i?) || repo_data["stars"]?.try(&.as_i?) || 0
    default_branch = repo_data["default_branch"]?.try(&.as_s?) || "main"

    begin
      repo = graph.add_object("repo", Repo.new(
        name: name,
        full_name: full_name,
        description: description,
        url: url,
        default_branch: default_branch,
        language: language,
        stars: stars,
        source_id: source_id,
      ).to_json, actor: "codebase.repo_ingester")
      repo_registry[full_name] = repo.id
      graph.add_relation(repo.id, source_id, "derived_from_source", actor: "codebase.repo_ingester")
    rescue
    end
  end

  # Create Issue objects from GitHub webhook events or plain issue sources.
  @[Chronicle::Packs::Annotations::Behavior(name: "issue_tracker", on: ["object.created"], where: {"type" => "source"}, creates: ["issue", "task"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream issue_tracker repo/task/issue branches
  def issue_tracker(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : CodebaseSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    source_id = payload["id"]?.try(&.as_s?)
    return if source_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    kind = data["kind"]?.try(&.as_s?) || ""
    meta = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any

    is_issue_source = kind == "issue" ||
                      (kind == "github_webhook" && {"issues", "issue"}.includes?(meta["event"]?.try(&.as_s?) || ""))
    return unless is_issue_source

    issue_data = meta["issue"]?.try(&.as_h?) || meta
    repo_data = meta["repository"]?.try(&.as_h?) || {} of String => JSON::Any
    full_name = repo_data["full_name"]?.try(&.as_s?) || meta["repo_full_name"]?.try(&.as_s?) || "unknown/unknown"

    issue_number = issue_data["number"]?.try(&.as_i?) || issue_data["issue_number"]?.try(&.as_i?) || 0
    issue_key = "#{full_name}##{issue_number}"

    return if issue_registry.has_key?(issue_key)

    title = issue_data["title"]?.try(&.as_s?)
    title = (data["content"]?.try(&.as_s?) || "")[0, 80] if title.nil? || title.empty?
    title = "Untitled Issue" if title.nil? || title.empty?
    body = issue_data["body"]?.try(&.as_s?) || data["content"]?.try(&.as_s?) || ""
    state = issue_data["state"]?.try(&.as_s?) || "open"
    labels = (issue_data["labels"]?.try(&.as_a?) || [] of JSON::Any).map do |label|
      if h = label.as_h?
        h["name"]?.try(&.as_s?) || ""
      else
        label.as_s
      end
    end
    user = issue_data["user"]?.try(&.as_h?) || {} of String => JSON::Any
    author_ref = user["login"]?.try(&.as_s?) || issue_data["author_ref"]?.try(&.as_s?)
    created_at = issue_data["created_at"]?.try(&.as_s?) || _now_iso

    repo_id = repo_registry[full_name]?

    if repo_id.nil?
      begin
        repo = graph.add_object("repo", Repo.new(
          name: full_name.includes?("/") ? full_name.split("/").last : full_name,
          full_name: full_name,
          source_id: source_id,
        ).to_json, actor: "codebase.issue_tracker")
        repo_id = repo.id
        repo_registry[full_name] = repo_id
      rescue
        return
      end
    end

    task_id : String? = nil
    if settings.auto_create_issues_as_tasks? && state == "open"
      begin
        priority = if labels.any? { |label| label.downcase == "bug" }
                     "high"
                   else
                     "medium"
                   end
        task = graph.add_object("task", {
          "title"       => JSON::Any.new("[Issue] #{title}"),
          "description" => JSON::Any.new(body[0, 500]),
          "status"      => JSON::Any.new("candidate"),
          "priority"    => JSON::Any.new(priority),
          "owner_ref"   => JSON::Any.new(author_ref),
        }.to_json, actor: "codebase.issue_tracker")
        task_id = task.id
      rescue
      end
    end

    begin
      issue = graph.add_object("issue", Issue.new(
        repo_id: repo_id,
        issue_number: issue_number,
        title: title,
        body: body[0, 2000],
        state: IssueState.parse?(state) || IssueState::Open,
        labels: labels,
        author_ref: author_ref,
        created_at: created_at,
        source_id: source_id,
        task_id: task_id,
      ).to_json, actor: "codebase.issue_tracker")
      issue_registry[issue_key] = issue.id
      graph.add_relation(issue.id, repo_id, "issue_in_repo", actor: "codebase.issue_tracker")
      graph.add_relation(issue.id, source_id, "derived_from_source", actor: "codebase.issue_tracker")
      if task_id
        begin
          graph.add_relation(issue.id, task_id, "action_creates_task", actor: "codebase.issue_tracker")
        rescue
        end
      end
    rescue
    end
  end

  # Extract Architecture Decision Records from repo file sources.
  @[Chronicle::Packs::Annotations::Behavior(name: "adr_extractor", on: ["object.created"], where: {"type" => "source"}, creates: ["architecture_decision"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream adr_extractor title/status/sections branches
  def adr_extractor(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : CodebaseSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    source_id = payload["id"]?.try(&.as_s?)
    return if source_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    return unless data["kind"]?.try(&.as_s?) == "repo_file"

    meta = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    path = meta["path"]?.try(&.as_s?) || meta["file_path"]?.try(&.as_s?) || ""

    return unless _is_adr_path(path, settings.adr_path_patterns)

    content = data["content"]?.try(&.as_s?) || ""
    full_name = meta["repo_full_name"]?.try(&.as_s?) || meta["full_name"]?.try(&.as_s?) || ""
    repo_id = repo_registry[full_name]?

    title_match = content.scan(/^#\s*([^\n]+)$/m).first?
    title = if title_match
              title_match[1]?.try(&.strip) || ""
            else
              filename = path.split("/").last
              filename.gsub("-", " ").titleize
            end

    adr_num_match = path.split("/").last.scan(/\d+/).first?
    adr_number = adr_num_match.try(&.[0]?).try(&.to_i?)

    status = "accepted"
    content_lower = content.downcase
    if content_lower.includes?("deprecated")
      status = "deprecated"
    elsif content_lower.includes?("proposed")
      status = "proposed"
    elsif content_lower.includes?("superseded")
      status = "superseded"
    end

    sections = _parse_adr_content(content)

    if repo_id.nil? && !full_name.empty?
      begin
        repo = graph.add_object("repo", Repo.new(
          name: full_name.includes?("/") ? full_name.split("/").last : full_name,
          full_name: full_name,
          source_id: source_id,
        ).to_json, actor: "codebase.adr_extractor")
        repo_id = repo.id
        repo_registry[full_name] = repo_id
      rescue
      end
    end

    begin
      adr = graph.add_object("architecture_decision", ArchitectureDecision.new(
        repo_id: repo_id || "",
        title: title,
        context: sections["context"][0, 1000],
        decision: sections["decision"][0, 1000],
        consequences: sections["consequences"][0, 500],
        status: AdrStatus.parse?(status) || AdrStatus::Proposed,
        adr_number: adr_number,
        source_id: source_id,
      ).to_json, actor: "codebase.adr_extractor")
      graph.add_relation(adr.id, source_id, "derived_from_source", actor: "codebase.adr_extractor")
      if repo_id
        graph.add_relation(adr.id, repo_id, "adr_in_repo", actor: "codebase.adr_extractor")
      end
    rescue
    end
  end

  # Summarize code changes from push/PR webhook sources.
  @[Chronicle::Packs::Annotations::Behavior(name: "change_summarizer", on: ["object.created"], where: {"type" => "source"}, creates: ["code_change"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream change_summarizer commit/pr branches
  def change_summarizer(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : CodebaseSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    source_id = payload["id"]?.try(&.as_s?)
    return if source_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    kind = data["kind"]?.try(&.as_s?) || ""
    meta = data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
    event_type = meta["event"]?.try(&.as_s?) || ""

    is_change_source = {"github_push", "code_change"}.includes?(kind) ||
                       (kind == "github_webhook" && {"push", "pull_request"}.includes?(event_type))
    return unless is_change_source

    repo_data = meta["repository"]?.try(&.as_h?) || {} of String => JSON::Any
    full_name = repo_data["full_name"]?.try(&.as_s?) || meta["repo_full_name"]?.try(&.as_s?) || "unknown/unknown"
    repo_id = repo_registry[full_name]?

    commits = meta["commits"]?.try(&.as_a?) || [] of JSON::Any
    pr_data = meta["pull_request"]?.try(&.as_h?) || {} of String => JSON::Any

    files_changed = [] of String
    lines_added = 0
    lines_removed = 0

    commits.each do |commit|
      ch = commit.as_h
      ch["added"]?.try(&.as_a?).try { |arr| arr.each { |file| files_changed << file.as_s } }
      ch["modified"]?.try(&.as_a?).try { |arr| arr.each { |file| files_changed << file.as_s } }
      ch["removed"]?.try(&.as_a?).try { |arr| arr.each { |file| files_changed << file.as_s } }
    end

    if !pr_data.empty?
      lines_added = pr_data["additions"]?.try(&.as_i?) || 0
      lines_removed = pr_data["deletions"]?.try(&.as_i?) || 0
    end

    commit_sha = meta["after"]?.try(&.as_s?)
    if commit_sha.nil? && !commits.empty?
      commit_sha = commits.first.as_h["id"]?.try(&.as_s?)
    end
    pusher = meta["pusher"]?.try(&.as_h?) || {} of String => JSON::Any
    sender = meta["sender"]?.try(&.as_h?) || {} of String => JSON::Any
    author = pusher["name"]?.try(&.as_s?) || sender["login"]?.try(&.as_s?)

    summary_parts = [] of String
    if !commits.empty?
      msgs = commits.first(3).map { |commit| (commit.as_h["message"]?.try(&.as_s?) || "")[0, 60] }
      summary_parts << "#{commits.size} commit(s): " + msgs.join("; ")
    elsif !pr_data.empty?
      summary_parts << "PR: #{(pr_data["title"]?.try(&.as_s?) || "")[0, 80]}"
    end
    summary = summary_parts.empty? ? "Code change" : summary_parts.join(" | ")

    if repo_id.nil? && !full_name.empty?
      begin
        repo = graph.add_object("repo", Repo.new(
          name: full_name.includes?("/") ? full_name.split("/").last : full_name,
          full_name: full_name,
          source_id: source_id,
        ).to_json, actor: "codebase.change_summarizer")
        repo_id = repo.id
        repo_registry[full_name] = repo_id
      rescue
      end
    end

    begin
      change = graph.add_object("code_change", CodeChange.new(
        repo_id: repo_id || "",
        summary: summary[0, 500],
        files_changed: files_changed.uniq.first(50),
        lines_added: lines_added,
        lines_removed: lines_removed,
        commit_sha: commit_sha,
        author_ref: author,
        source_id: source_id,
      ).to_json, actor: "codebase.change_summarizer")
      graph.add_relation(change.id, source_id, "derived_from_source", actor: "codebase.change_summarizer")
      if repo_id
        graph.add_relation(change.id, repo_id, "change_in_repo", actor: "codebase.change_summarizer")
      end
    rescue
    end
  end

  # Create Dependency objects from repo metadata.
  @[Chronicle::Packs::Annotations::Behavior(name: "dependency_auditor", on: ["object.created"], where: {"type" => "repo"}, creates: ["dependency"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream dependency_auditor severity-gate branches
  def dependency_auditor(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : CodebaseSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    repo_id = payload["id"]?.try(&.as_s?)
    return if repo_id.nil?
    data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any

    source_id = data["source_id"]?.try(&.as_s?)
    return if source_id.nil?

    begin
      source = graph.get_object(source_id)
      return if source.nil?
      meta = JSON.parse(source.data)["metadata"]?.try(&.as_h?) || {} of String => JSON::Any
      deps = meta["dependencies"]?.try(&.as_a?) || [] of JSON::Any
    rescue
      return
    end

    sev_threshold_order = {"low" => 0, "medium" => 1, "high" => 2, "critical" => 3}
    min_sev = sev_threshold_order[settings.vulnerability_severity_threshold]? || 1

    deps.first(100).each do |dep|
      next unless h = dep.as_h?
      dep_name = h["name"]?.try(&.as_s?) || ""
      next if dep_name.empty?

      vuln = h["vulnerability"]?.try(&.as_h?) || {} of String => JSON::Any
      has_vuln = !vuln.empty?
      vuln_sev = vuln["severity"]?.try(&.as_s?) || "low"
      vuln_meets_threshold = (sev_threshold_order[vuln_sev]? || 0) >= min_sev

      begin
        dep_obj = graph.add_object("dependency", Dependency.new(
          repo_id: repo_id,
          name: dep_name,
          version: h["version"]?.try(&.as_s?),
          kind: DependencyKind.parse?(h["kind"]?.try(&.as_s?) || "direct") || DependencyKind::Direct,
          ecosystem: h["ecosystem"]?.try(&.as_s?) || "",
          has_known_vulnerability: has_vuln && vuln_meets_threshold,
          vulnerability_summary: vuln["summary"]?.try(&.as_s?) || "",
        ).to_json, actor: "codebase.dependency_auditor")
        graph.add_relation(repo_id, dep_obj.id, "repo_depends_on", actor: "codebase.dependency_auditor")
      rescue
      end
    end
  end
end
