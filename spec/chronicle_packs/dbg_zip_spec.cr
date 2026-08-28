require "spec"
require "../spec_helper"
require "compress/zlib"
require "compress/deflate"
require "compress/gzip"

describe "zip dbg" do
  it "lists stdlib compress" do
    puts "zlib=#{Compress::Zlib.class}"
  end
end
