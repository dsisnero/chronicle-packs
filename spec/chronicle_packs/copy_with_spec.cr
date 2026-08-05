require "spec"
require "../spec_helper"

# CopyWith auto-derivation: define_copy_with with no args derives the
# field list from the struct's instance variables, so a partial override
# keeps every other ivar's current value.

struct CopyWithSample
  include Chronicle::Packs::CopyWith
  include JSON::Serializable

  getter label : String
  getter count : Int32 = 0
  getter? visible : Bool = true
  getter score : Float64 = 0.0

  def initialize(@label : String, @count : Int32 = 0, @visible : Bool = true, @score : Float64 = 0.0)
  end

  define_copy_with
end

describe "CopyWith auto-derivation" do
  it "keeps current values for unset fields" do
    sample = CopyWithSample.new("a", 3, false, 0.5)
    sample.copy_with(label: "b").should eq(CopyWithSample.new("b", 3, false, 0.5))
  end

  it "overrides falsy values explicitly" do
    sample = CopyWithSample.new("a", 3, true, 0.5)
    sample.copy_with(visible: false).visible?.should be_false
    sample.copy_with(count: 0).count.should eq(0)
    sample.copy_with(score: 0.0).score.should eq(0.0)
  end

  it "overrides multiple fields at once" do
    sample = CopyWithSample.new("a", 3, true, 0.5)
    sample.copy_with(count: 9, visible: false, score: 2.5).should eq(CopyWithSample.new("a", 9, false, 2.5))
  end

  it "returns an equal copy when called with no overrides" do
    sample = CopyWithSample.new("a", 3, false, 0.5)
    sample.copy_with.should eq(sample)
  end
end
