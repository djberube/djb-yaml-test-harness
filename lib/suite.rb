# frozen_string_literal: true

require 'open3'
require_relative 'config'

# The yaml-test-suite checkout, and the cases read out of it.
#
# The suite is cloned on demand into a gitignored vendor/ directory rather than
# vendored, so this repo stays the harness and not a copy of someone else's
# test corpus. The ref is pinned in Config, since an unpinned suite would make
# two runs of the same harness disagree for reasons that have nothing to do
# with the parsers.
module Suite
  Error = Class.new(StandardError)

  # One test case. `events` is the suite's expected event stream, already
  # normalized; `error` marks a document the parser is *supposed* to reject,
  # for which the suite ships no event stream.
  Case = Struct.new(:id, :yaml, :events, :error, :label, keyword_init: true) do
    def error? = error
  end

  class << self
    def ensure_checkout
      return Config::SUITE_DIR if File.directory?(File.join(Config::SUITE_DIR, '.git'))

      FileUtils.mkdir_p(File.dirname(Config::SUITE_DIR))
      warn "cloning yaml-test-suite @ #{Config::SUITE_REF} (once; gitignored)..."

      out, status = Open3.capture2e(
        'git', 'clone', '--depth', '1', '--branch', Config::SUITE_REF,
        Config::SUITE_URL, Config::SUITE_DIR
      )
      raise Error, "git clone failed:\n#{out}" unless status.success?

      Config::SUITE_DIR
    end

    # Every case in the suite, sorted by id.
    #
    # A case is either a directory holding in.yaml directly, or a directory of
    # numbered subdirectories each holding one. The numbered form is how the
    # suite groups variations on a theme, and the ids it produces (`DK95#04`)
    # are the ones the suite's own reports use, so they are reproduced here.
    def cases(filter: nil)
      root = ensure_checkout
      found = []

      Dir.children(root).sort.each do |name|
        dir = File.join(root, name)
        next unless File.directory?(dir) && name.match?(/\A[0-9A-Z]{4}\z/)

        if File.exist?(File.join(dir, 'in.yaml'))
          found << build(name, dir)
        else
          Dir.children(dir).sort.grep(/\A\d+\z/).each do |sub|
            subdir = File.join(dir, sub)
            next unless File.exist?(File.join(subdir, 'in.yaml'))

            found << build("#{name}##{sub.to_i}", subdir)
          end
        end
      end

      found.compact!
      return found unless filter

      rx = Regexp.new(filter, Regexp::IGNORECASE)
      found.select { |c| c.id.match?(rx) }
    end

    private

    def build(id, dir)
      events_path = File.join(dir, 'test.event')
      Case.new(
        id: id,
        yaml: File.read(File.join(dir, 'in.yaml')),
        events: File.exist?(events_path) ? normalize(File.read(events_path)) : nil,
        error: File.exist?(File.join(dir, 'error')),
        label: first_line(File.join(dir, '==='))
      )
    end

    def first_line(path)
      File.exist?(path) ? File.read(path).lines.first.to_s.strip : nil
    end

    # Trim trailing whitespace and drop blank lines so a parser is not marked
    # wrong for formatting. Everything else -- including the scalar style
    # indicators after `=VAL` -- is significant and left alone.
    def normalize(text)
      text.split("\n").map(&:rstrip).reject(&:empty?)
    end
  end
end

require 'fileutils'
