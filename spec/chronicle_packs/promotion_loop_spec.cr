require "spec"
require "../spec_helper"

# P6 promotion-loop acceptance includes a hard architectural boundary: policy
# promotion is driven by recorded verdicts and evidence, never product scores
# or the predictor's internal state.  The behavioral portions live with their
# owning packs; this source-level assertion keeps the shared boundary visible.
describe "promotion-loop policy boundary" do
  it "does not couple governed promotion to product scoring or predictor state" do
    root = Path[__DIR__].parent.parent
    [
      root / "src/chronicle_packs/tool_gateway/standing_scopes.cr",
      root / "src/chronicle_packs/memory_gateway/promotion.cr",
      root / "src/chronicle_packs/skills/verification.cr",
    ].each do |path|
      source = File.read(path)
      ["total_score", "project_score", "babyagi"].each do |forbidden|
        source.includes?(forbidden).should be_false
      end
    end
  end
end
