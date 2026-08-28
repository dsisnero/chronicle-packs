require "spec"
require "../spec_helper"

# Codebase Pack (packs/codebase): repo ingestion, issue/PR tracking, ADR
# extraction, code change summarization, dependency auditing. Translated from
# upstream packs/codebase/* (revision 6639a5385518ad49f74813373c85cf96eff9adc0).

module CodebaseSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def codebase_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "codebase" / "manifest.toml"
  end

  # Mirrors upstream fixtures/run_fixtures.py _make_runtime (Core + codebase).
  def with_codebase_runtime(
    auto_create_issues_as_tasks : Bool = true,
    adr_path_patterns : Array(String) = ["docs/adr", "adr/"],
    vulnerability_severity_threshold : String = "medium",
    &
  )
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    settings = Chronicle::Packs::Codebase::CodebaseSettings.new(
      auto_create_issues_as_tasks: auto_create_issues_as_tasks,
      adr_path_patterns: adr_path_patterns,
      vulnerability_severity_threshold: vulnerability_severity_threshold,
    )
    rt.load_pack(Chronicle::Packs::Codebase.pack, JSON.parse(settings.to_json).as_h).should be_true
    Chronicle::Packs::Codebase.clear_codebase_registry
    yield store, graph, rt
  ensure
    Chronicle::Packs::Codebase.clear_codebase_registry
  end

  ADR_CONTENT = <<-ADR
    # ADR-001: Use CUDA-optimized attention kernels

    ## Context
    Our inference engine needs to handle batch sizes up to 256 efficiently.
    Standard PyTorch attention is not optimized for our memory access patterns.

    ## Decision
    We will use FlashAttention v2 as our primary attention implementation.
    For CPU fallback, we use standard scaled dot-product attention.

    ## Consequences
    - Faster inference on CUDA devices (40% improvement in benchmarks)
    - Additional dependency on flash-attn package
    - CPU performance unchanged
    ADR
end

include CodebaseSpecSupport

describe Chronicle::Packs::Codebase do
  describe "manifest-declared surface" do
    it "matches the upstream codebase manifest" do
      pack = Chronicle::Packs::Codebase.pack
      pack.name.should eq("codebase")
      pack.version.should eq("0.1.2")
      pack.object_types.map(&.name).should eq(
        ["repo", "code_file", "code_function", "dependency", "issue", "pull_request", "architecture_decision", "code_change", "test_result"]
      )
      pack.relation_types.map(&.name).should eq(
        ["file_in_repo", "function_in_file", "repo_depends_on", "issue_in_repo", "pr_in_repo", "adr_in_repo", "change_in_repo", "test_for_repo"]
      )
      pack.behaviors.map(&.name).should eq(
        ["repo_ingester", "issue_tracker", "adr_extractor", "change_summarizer", "dependency_auditor"]
      )
      pack.tools.map(&.name).should eq(
        ["ingest_github_webhook", "ingest_repo_file", "create_repo", "create_issue"]
      )
      pack.settings_schema.should eq("CodebaseSettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(codebase_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::Codebase.pack)
    end
  end

  describe "fixture: repo_and_issue_tracking" do
    it "turns a repo manifest + issue + ADR into Repo/Dependencies/Issue/task/ArchitectureDecision" do
      with_codebase_runtime do |_store, graph, rt|
        Chronicle::Packs::Codebase.create_repo_fn(
          graph,
          full_name: "acme-corp/inference-engine",
          description: "High-performance LLM inference engine",
          language: "python",
          url: "https://github.com/acme-corp/inference-engine",
          dependencies: [
            {"name" => JSON::Any.new("torch"), "version" => JSON::Any.new("2.1.0"), "kind" => JSON::Any.new("direct"), "ecosystem" => JSON::Any.new("pypi")},
            {"name" => JSON::Any.new("numpy"), "version" => JSON::Any.new("1.26.0"), "kind" => JSON::Any.new("direct"), "ecosystem" => JSON::Any.new("pypi")},
            {"name" => JSON::Any.new("requests"), "version" => JSON::Any.new("2.31.0"), "kind" => JSON::Any.new("direct"), "ecosystem" => JSON::Any.new("pypi"),
             "vulnerability" => JSON::Any.new({"severity" => JSON::Any.new("high"), "summary" => JSON::Any.new("CVE-2023-XXXX: SSRF via redirects")})},
          ],
        )
        rt.run_until_idle

        repos = graph.objects(type: "repo")
        repos.size.should eq(1)
        repo_data = JSON.parse(repos.first.data)
        repo_data["full_name"].as_s.should eq("acme-corp/inference-engine")
        repo_data["language"].as_s.should eq("python")

        deps = graph.objects(type: "dependency")
        deps.size.should eq(3)
        vuln_deps = deps.select { |d| JSON.parse(d.data)["has_known_vulnerability"].as_bool }
        vuln_deps.size.should eq(1)
        JSON.parse(vuln_deps.first.data)["name"].as_s.should eq("requests")

        Chronicle::Packs::Codebase.create_issue_fn(
          graph,
          repo_full_name: "acme-corp/inference-engine",
          issue_number: 42,
          title: "Memory leak in batch inference mode",
          body: "When running batch sizes > 32, memory usage grows unboundedly. Affects CUDA backend.",
          state: "open",
          labels: ["bug", "performance"],
          author_ref: "eng-alice",
        )
        rt.run_until_idle

        issues = graph.objects(type: "issue")
        issues.size.should eq(1)
        issue_data = JSON.parse(issues.first.data)
        issue_data["issue_number"].as_i.should eq(42)
        issue_data["title"].as_s.should eq("Memory leak in batch inference mode")
        issue_data["state"].as_s.should eq("open")
        issue_data["labels"].as_a.map(&.as_s).should eq(["bug", "performance"])
        issue_data["task_id"].as_s?.should_not be_nil

        tasks = graph.objects(type: "task")
        tasks.size.should eq(1)
        JSON.parse(tasks.first.data)["priority"].as_s.should eq("high")

        Chronicle::Packs::Codebase.ingest_repo_file_fn(
          graph,
          repo_full_name: "acme-corp/inference-engine",
          path: "docs/adr/001-attention-kernels.md",
          content: ADR_CONTENT,
          language: "markdown",
        )
        rt.run_until_idle

        adrs = graph.objects(type: "architecture_decision")
        adrs.size.should eq(1)
        adr_data = JSON.parse(adrs.first.data)
        adr_data["status"].as_s.should eq("accepted")
        adr_data["adr_number"].as_i.should eq(1)
        adr_data["title"].as_s.should eq("ADR-001: Use CUDA-optimized attention kernels")
        adr_data["context"].as_s.starts_with?("Our inference engine").should be_true
        adr_data["decision"].as_s.starts_with?("We will use FlashAttention").should be_true

        rel_types = graph.relations.map(&.type).to_set
        rel_types.should contain("derived_from_source")
        rel_types.should contain("repo_depends_on")
        rel_types.should contain("issue_in_repo")
        rel_types.should contain("adr_in_repo")
      end
    end

    it "dedups issue ingestion by repo#number" do
      with_codebase_runtime do |_store, graph, rt|
        Chronicle::Packs::Codebase.create_repo_fn(graph, full_name: "acme-corp/inference-engine")
        rt.run_until_idle
        2.times do
          Chronicle::Packs::Codebase.create_issue_fn(
            graph, repo_full_name: "acme-corp/inference-engine", issue_number: 7,
            title: "Duplicate issue", body: "Same issue delivered twice",
          )
          rt.run_until_idle
        end
        graph.objects(type: "issue").size.should eq(1)
      end
    end
  end

  describe "fixture: code_change_tracking" do
    it "summarizes a push webhook into a CodeChange with files and commit sha" do
      with_codebase_runtime do |_store, graph, rt|
        Chronicle::Packs::Codebase.create_repo_fn(graph, full_name: "acme-corp/inference-engine")
        rt.run_until_idle

        Chronicle::Packs::Codebase.ingest_github_webhook_fn(
          graph,
          event: "push",
          payload: {
            "repository" => JSON::Any.new({"full_name" => JSON::Any.new("acme-corp/inference-engine")}),
            "after"      => JSON::Any.new("abc123def456"),
            "pusher"     => JSON::Any.new({"name" => JSON::Any.new("eng-bob")}),
            "commits"    => JSON::Any.new([
              JSON::Any.new({
                "id"       => JSON::Any.new("abc123def456"),
                "message"  => JSON::Any.new("Fix memory leak in batch inference mode (#42)"),
                "added"    => JSON::Any.new([] of JSON::Any),
                "modified" => JSON::Any.new([JSON::Any.new("src/inference/batch.py"), JSON::Any.new("src/inference/cuda_backend.py")]),
                "removed"  => JSON::Any.new([] of JSON::Any),
              }),
              JSON::Any.new({
                "id"       => JSON::Any.new("def456ghi789"),
                "message"  => JSON::Any.new("Add test coverage for batch sizes > 32"),
                "added"    => JSON::Any.new([JSON::Any.new("tests/test_batch_memory.py")]),
                "modified" => JSON::Any.new([] of JSON::Any),
                "removed"  => JSON::Any.new([] of JSON::Any),
              }),
            ]),
          },
        )
        rt.run_until_idle

        changes = graph.objects(type: "code_change")
        changes.size.should eq(1)
        change_data = JSON.parse(changes.first.data)
        change_data["commit_sha"].as_s.should eq("abc123def456")
        change_data["author_ref"].as_s.should eq("eng-bob")
        change_data["files_changed"].as_a.map(&.as_s).to_set.should eq(
          Set{"src/inference/batch.py", "src/inference/cuda_backend.py", "tests/test_batch_memory.py"}
        )
        change_data["summary"].as_s.starts_with?("2 commit(s):").should be_true

        rel_types = graph.relations.map(&.type).to_set
        rel_types.should contain("change_in_repo")
      end
    end
  end

  describe "dependency_auditor gating" do
    it "does not flag a vulnerability below the severity threshold" do
      with_codebase_runtime(vulnerability_severity_threshold: "critical") do |_store, graph, rt|
        Chronicle::Packs::Codebase.create_repo_fn(
          graph,
          full_name: "acme-corp/app",
          dependencies: [
            {"name" => JSON::Any.new("requests"), "version" => JSON::Any.new("2.31.0"), "kind" => JSON::Any.new("direct"), "ecosystem" => JSON::Any.new("pypi"),
             "vulnerability" => JSON::Any.new({"severity" => JSON::Any.new("high"), "summary" => JSON::Any.new("CVE-2023-XXXX")})},
          ],
        )
        rt.run_until_idle

        deps = graph.objects(type: "dependency")
        deps.size.should eq(1)
        JSON.parse(deps.first.data)["has_known_vulnerability"].as_bool.should be_false
      end
    end

    it "skips direction synthesis unrelated behavior when issue auto-create is off" do
      with_codebase_runtime(auto_create_issues_as_tasks: false) do |_store, graph, rt|
        Chronicle::Packs::Codebase.create_repo_fn(graph, full_name: "acme-corp/app")
        rt.run_until_idle
        Chronicle::Packs::Codebase.create_issue_fn(
          graph, repo_full_name: "acme-corp/app", issue_number: 1,
          title: "Open issue", state: "open",
        )
        rt.run_until_idle

        graph.objects(type: "issue").size.should eq(1)
        graph.objects(type: "task").size.should eq(0)
        JSON.parse(graph.objects(type: "issue").first.data)["task_id"]?.try(&.as_s?).should be_nil
      end
    end
  end
end
