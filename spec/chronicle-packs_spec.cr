require "./spec_helper"

describe Chronicle::Packs do
  it "has a version" do
    Chronicle::Packs::VERSION.should_not be_empty
  end
end
