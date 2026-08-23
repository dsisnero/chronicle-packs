module Chronicle::Packs::Evolution
  # Pure, non-executing checks over a candidate pack's authored files.
  module Analysis
    extend self

    FIXTURE_FILE   = "fixtures/run_fixtures.py"
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

    # Gate -1: the author may not overwrite charter or other human-only
    # files, including by hiding a reserved basename in a subdirectory.
    def check_reserved_paths(files : Hash(String, String), reserved_paths : Array(String)) : Array(String)
      violations = [] of String
      files.each_key do |path|
        basename = path.rpartition('/')[2]
        if reserved_paths.includes?(path) || reserved_paths.includes?(basename)
          violations << "authored file '#{path}' targets reserved path (charter and other human-PR-only files are never authorable)"
        end
      end
      violations
    end

    # The fixture is executed by the trial child, which invokes only a
    # top-level `main(rt)` function. Nested definitions are not entrypoints.
    def check_fixture_entrypoint(files : Hash(String, String)) : Array(String)
      source = files[FIXTURE_FILE]? || ""
      return [] of String if source.each_line.any? { |line| line.matches?(/^def main\(rt\):/) }

      ["#{FIXTURE_FILE}: no module-level `def main(rt)` (the trial child's scenario entrypoint)"]
    end
  end
end
