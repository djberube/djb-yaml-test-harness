# frozen_string_literal: true

require 'yaml'
require_relative 'config'
require_relative 'suite'

# The local case corpus, read from data/custom_cases/.
#
# These are documents this project cares about that the yaml-test-suite does
# not cover -- a directive nobody implements, a construct that turned up in a
# real config file, whatever the last bug report was about. They are kept
# separate from the suite on purpose, and separate in both directions:
#
#   * they carry no expectation. The suite states what a parser should build
#     and scores against it; a custom case asks the weaker and more useful
#     question of what each parser *does*, with no claim about what is right.
#     There is no oracle here, so there is nothing to pass or fail.
#
#   * they never enter the scored totals. A pass rate is a number against a
#     fixed published corpus, and quietly adding local cases to it would make
#     "81.7%" mean something different in this checkout than anywhere else.
#     Custom cases get their own directory under reports/ and touch nothing in
#     the summary tables.
#
# A file is one document, verbatim -- no wrapper, no metadata, nothing to
# unescape. Whatever bytes are in data/custom_cases/foo.yml are the bytes fed
# to every parser. That is deliberate: the suite's src/ format exists to carry
# expectations alongside the document, and with no expectations to carry, a
# plain file is both simpler to add and unambiguous about what is being parsed.
module CustomCases
  # Relative to the repo root, or absolute if the override is. `File.expand_path`
  # with a base leaves an absolute path alone, which File.join would not --
  # it would happily produce ROOT + "/tmp/whatever".
  DIR = File.expand_path(
    ENV.fetch('YAML_CUSTOM_DIR', File.join('data', 'custom_cases')), Config::ROOT
  )

  # Both spellings, because both are in common use and which one a contributor
  # reaches for is not worth having an opinion about.
  EXTENSIONS = %w[.yml .yaml].freeze

  class << self
    # Every custom case, sorted by id.
    #
    # Reuses Suite::Case so the runner and the report code do not need a second
    # shape to handle. `events`, `json` and `error` are all nil: there is no
    # expectation, which is the whole point.
    def cases(filter: nil)
      return [] unless File.directory?(DIR)

      found = Dir.children(DIR).sort.filter_map do |name|
        next unless EXTENSIONS.include?(File.extname(name))

        build(File.join(DIR, name))
      end

      return found unless filter

      rx = Regexp.new(filter, Regexp::IGNORECASE)
      found.select { |c| c.id.match?(rx) }
    end

    def any? = !cases.empty?

    private

    def build(path)
      id = File.basename(path, File.extname(path))

      # Read as binary and hand the bytes over untouched. A custom case is
      # quite likely to be about an encoding or a stray control character, and
      # letting Ruby transcode on the way in would quietly fix the thing being
      # tested.
      label, yaml = split_label(File.binread(path))

      Suite::Case.new(
        id: id,
        yaml: yaml,
        events: nil,
        json: nil,
        error: nil,
        label: label,
        tags: []
      )
    end

    # A leading `# name:` comment, if the file opens with one, is the case's
    # label and is *removed* from the document.
    #
    # Removed rather than left in place because it is metadata, not content,
    # and leaving it would change what is being tested. A `%YAML` or `%TAG`
    # directive has to precede everything in its document, so a case about
    # directive handling with a comment above the directive is a case about
    # something else. Anywhere else in the file a comment is inert and this
    # would not matter; at the top it is exactly where it does.
    #
    # The label is optional. A file named unknown_directive.yml has already
    # said most of what a label would, and a case whose first line is a
    # meaningful comment simply does not get one.
    def split_label(text)
      first, rest = text.split("\n", 2)
      m = first.to_s.match(/\A#\s*name:\s*(.+?)\s*\z/)
      return [nil, text] if m.nil?

      [m[1], rest.to_s]
    end
  end
end
