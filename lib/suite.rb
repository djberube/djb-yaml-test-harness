# frozen_string_literal: true

require 'open3'
require 'yaml'
require_relative 'config'

# The yaml-test-suite checkout, and the cases read out of it.
#
# The suite is cloned on demand into a gitignored vendor/ directory rather than
# vendored, so this repo stays the harness and not a copy of someone else's
# test corpus. The ref is pinned in Config.
#
# Cases are read from `src/`, the suite's own source form: 351 files, each an
# ordinary YAML sequence of one or more cases. The suite also publishes
# generated `data-*` tags with one directory per case, which is an easier
# layout to read -- but the newest is data-2022-01-17, and more importantly the
# generated form ships `in.json` for only two thirds of the cases it applies
# to. `src/` carries `tree:` and `json:` side by side for every case that has
# them, which is what lets one run score both.
module Suite
  Error = Class.new(StandardError)

  # One test case.
  #
  #   events  the suite's expected event stream (its `tree:`), normalized
  #   json    the suite's expected *loaded value* (its `json:`), as a JSON
  #           string, or nil for the cases that do not specify one
  #   error   a document the parser is supposed to reject, for which the suite
  #           ships no expectation at all
  #
  # A case can have events without json: the suite omits `json:` where the
  # document has no meaningful JSON projection (an empty stream, a duplicate
  # key, a value JSON cannot represent). Those cases score in the event run and
  # sit out the value run rather than being counted as passes in it.
  Case = Struct.new(:id, :yaml, :events, :json, :error, :label, :tags,
                    keyword_init: true) do
    def error? = error
    def value? = !error && !json.nil?
  end

  class << self
    def ensure_checkout
      return Config::SUITE_DIR if checked_out?

      FileUtils.mkdir_p(File.dirname(Config::SUITE_DIR))
      warn "cloning yaml-test-suite @ #{Config::SUITE_REF} (once; gitignored)..."

      # Full clone rather than --depth 1 --branch: the ref is a commit sha, and
      # a shallow clone cannot check out an arbitrary commit. The repo is small.
      out, status = Open3.capture2e('git', 'clone', Config::SUITE_URL, Config::SUITE_DIR)
      raise Error, "git clone failed:\n#{out}" unless status.success?

      out, status = Open3.capture2e('git', '-C', Config::SUITE_DIR, 'checkout', '--quiet', Config::SUITE_REF)
      raise Error, "git checkout #{Config::SUITE_REF} failed:\n#{out}" unless status.success?

      Config::SUITE_DIR
    end

    # Every case in the suite, sorted by id.
    #
    # A file holding one case is that case; a file holding several yields
    # `DK95#0`, `DK95#1` and so on. The suffix is the index within the file,
    # which is how the suite's own generated layout numbers them.
    def cases(filter: nil)
      root = ensure_checkout
      src = File.join(root, 'src')
      raise Error, "no src/ in #{root}; is #{Config::SUITE_REF} a src-layout ref?" unless File.directory?(src)

      found = Dir.children(src).sort.flat_map do |name|
        next [] unless name.end_with?('.yaml')

        read_file(File.join(src, name), File.basename(name, '.yaml'))
      end

      return found unless filter

      rx = Regexp.new(filter, Regexp::IGNORECASE)
      found.select { |c| c.id.match?(rx) }
    end

    private

    def checked_out?
      return false unless File.directory?(File.join(Config::SUITE_DIR, '.git'))

      head, status = Open3.capture2e('git', '-C', Config::SUITE_DIR, 'rev-parse', 'HEAD')
      return false unless status.success?

      # A checkout of some other ref is not the pinned corpus. Re-clone rather
      # than silently reporting numbers from whatever happens to be on disk.
      head.strip.start_with?(Config::SUITE_REF)
    end

    def read_file(path, id)
      docs = YAML.unsafe_load_file(path)
      return [] unless docs.is_a?(Array)

      # `name` and `tags` are stated once on the first case in a file and
      # inherited by the rest, which is how the suite's own tooling reads them.
      name = nil
      tags = nil

      docs.each_with_index.filter_map do |tc, idx|
        next unless tc.is_a?(Hash) && tc['yaml']

        name ||= tc['name']
        tags ||= tc['tags']
        next if tc['skip']

        build(docs.size > 1 ? "#{id}##{idx}" : id, tc, name, tags)
      end
    end

    def build(id, doc, name, tags)
      Case.new(
        id: id,
        yaml: unescape(doc['yaml']),
        events: doc['tree'] ? normalize(unescape(doc['tree'])) : nil,
        json: doc['json'],
        error: doc['fail'] == true,
        label: doc['name'] || name,
        tags: (doc['tags'] || tags || '').split
      )
    end

    # The suite writes characters that would otherwise be invisible or eaten by
    # an editor as glyphs. These substitutions are the ones bin/YAMLTestSuite.pm
    # applies when generating the `data-*` layout, and reproducing them exactly
    # is what makes a case here the same case the suite publishes.
    #
    # Note `↵` is *removed*, not turned into a newline: it marks a line that
    # already ends there, so converting it would add a line the case does not
    # have. And the tab glyph is any run of em-dashes followed by `»`, not a
    # fixed set -- runs of up to four occur in the corpus.
    def unescape(text)
      return nil if text.nil?

      text.gsub('␣', ' ')
          .gsub(/—*»/, "\t")
          .gsub('←', "\r")
          .gsub('⇔', "﻿")
          .gsub('↵', '')
          .sub(/∎\n\z/, '')
    end

    # Trim trailing whitespace and drop blank lines so a parser is not marked
    # wrong for formatting. Everything else -- including the scalar style
    # indicators after `=VAL` -- is significant and left alone.
    #
    # The suite indents `tree:` for readability; the event stream itself is not
    # indented, so leading whitespace goes too.
    def normalize(text)
      text.split("\n").map(&:strip).reject(&:empty?)
    end
  end
end

require 'fileutils'
