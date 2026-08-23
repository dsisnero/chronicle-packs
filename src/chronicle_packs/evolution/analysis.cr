module Chronicle::Packs::Evolution
  # Pure, non-executing checks over a candidate pack's authored files.
  module Analysis
    extend self

    FIXTURE_FILE = "fixtures/run_fixtures.py"
    REQUIRED_FILES = ["manifest.toml", "__init__.py", FIXTURE_FILE]

    # Gate 0: candidates may contain only the configured file set and must
    # provide the manifest, module entrypoint, and trial fixture.
    def check_file_set(files : Hash(String, String), allowed : Array(String)) : Array(String)
      violations = [] of String
      files.each_key do |path|
        violations << "file not in the authored set: #{path}" unless allowed.includes?(path)
      end
      REQUIRED_FILES.each do |path|
        violations << "missing required file: #{path}" unless files.has_key?(path)
      end
      violations
    end
  end
end
