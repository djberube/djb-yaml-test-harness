# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'
require_relative 'config'
require_relative 'parsers'
require_relative 'report'

# reports/custom_cases/ -- one file per document in data/custom_cases/.
#
# Structurally this is the per-case view from case_report.rb, with the scoring
# removed. There is no expectation for these documents (see lib/custom_cases.rb
# for why), so there is no pass column, no failure kind, and no totals: the
# report says what each parser did and groups the parsers that did the same
# thing, and stops there.
#
# Everything here writes under reports/custom_cases/ and nothing here touches
# the scored reports. A custom case must not be able to move a pass rate.
module CustomReport
  DIRNAME = 'custom_cases'

  # Named for what the reader is looking at, not for the internal mode symbol.
  MODE_TITLE = {
    events: 'Event streams',
    value: 'Loaded values'
  }.freeze

  MODE_BLURB = {
    events: 'What each parser built',
    value: 'What each library resolved the document into'
  }.freeze

  # One mode's observations over the whole custom corpus.
  #
  # The scored side has Report::Run for this; a Probe is the same idea without
  # the results, because there are none. It carries enough to answer "who did
  # what" and "who agreed with whom", which is all these cases support.
  Probe = Struct.new(:observations, :parsers, :versions, :cases, :mode,
                     :started_at, :finished_at, keyword_init: true) do
    def cases_by_id
      @cases_by_id ||= (cases || []).to_h { |c| [c.id, c] }
    end

    def case_ids = (cases || []).map(&:id)

    def index
      @index ||= observations.to_h { |o| [[o.case_id, o.parser], o] }
    end

    def for(parser, case_id) = index[[case_id, parser]]

    # The camps on one case: {comparable output => [parser, ...]}.
    #
    # This is the interesting structure for an unjudged case. With no right
    # answer to sort parsers into pass and fail, the substance of a custom case
    # is which parsers landed in the same place -- one camp means the document
    # is uncontroversial, three camps means it is a real fault line.
    def camps(case_id)
      out = Hash.new { |h, k| h[k] = [] }
      parsers.each do |p|
        o = self.for(p, case_id)
        next if o.nil?

        c = o.comparable
        out[c] << p unless c.nil?
      end
      out
    end

    def unanimous?(case_id) = camps(case_id).size == 1

    def duration
      return nil unless started_at && finished_at

      finished_at - started_at
    end
  end

  class << self
    def write_all(probes, dir: Config::REPORT_DIR)
      probes = Array(probes).compact
      return {} if probes.empty?

      out_dir = File.join(dir, DIRNAME)
      FileUtils.mkdir_p(out_dir)

      # Clear the previous run's pages so a case deleted from data/custom_cases
      # stops having one. Scoped to the .md files this writes rather than an
      # rm_rf, since --out can point anywhere.
      Dir.glob(File.join(out_dir, '*.md')).each { |f| File.delete(f) }

      ids = probes.flat_map(&:case_ids).uniq.sort
      written = ids.to_h do |id|
        path = File.join(out_dir, "#{filename(id)}.md")
        File.write(path, page(id, probes))
        [id, path]
      end

      File.write(File.join(out_dir, 'README.md'), index(ids, probes))
      File.write(File.join(out_dir, 'custom_cases.json'),
                 JSON.pretty_generate(as_json(ids, probes)))
      written
    end

    # Case ids come from filenames, so they are already filesystem-safe; the
    # substitution is here anyway so an id and its page agree no matter what a
    # future loader allows.
    def filename(case_id) = case_id.tr('#/', '--')

    # --- one case ------------------------------------------------------------

    def page(id, probes)
      kase = probes.filter_map { |p| p.cases_by_id[id] }.first

      out = +"# #{id}"
      out << " — #{text(kase.label)}" if kase&.label && !kase.label.to_s.strip.empty?
      out << "\n\n"
      out << "A local case from `data/custom_cases/`. It states no expectation and\n"
      out << "is not scored: nothing below is a pass or a failure, and none of it\n"
      out << "counts toward any parser's totals.\n\n"
      out << source_section(kase) if kase
      probes.each { |probe| out << probe_section(id, probe) }
      out
    end

    def source_section(kase)
      out = +"## Document\n\n"
      # Chomped: the fence supplies the closing newline, and a document that
      # ends in one would otherwise render with a blank line before it.
      out << fence(text(kase.yaml).chomp)
      out
    end

    def probe_section(id, probe)
      rows = probe.parsers.map { |p| [p, probe.for(p, id)] }
      return '' if rows.all? { |_, o| o.nil? }

      camps = probe.camps(id)

      out = +"\n## #{MODE_TITLE[probe.mode] || probe.mode}\n\n"
      out << "#{MODE_BLURB[probe.mode]}.\n\n"

      # The headline for an unjudged case is the split, not a count of
      # anything. One camp is a document everyone agrees about; more than one
      # is the reason the case is in this directory.
      out << if camps.size <= 1
               "All #{probe.parsers.size} parsers produced the same output.\n\n"
             else
               "The #{probe.parsers.size} parsers split #{camps.size} ways.\n\n"
             end

      out << Report.md_table(
        %w[parser outcome result],
        rows.sort_by { |p, o| [outcome_order(o), p] }.map do |p, o|
          [Parsers[p][:label], outcome_label(o), inline(summary(o))]
        end
      )

      out << outputs_section(camps, probe)
      out
    end

    # What each camp produced, once per distinct output rather than once per
    # parser. Eleven parsers usually produce two or three distinct answers, and
    # printing the same stream eleven times would make the file unreadable for
    # no added information.
    def outputs_section(camps, probe)
      return '' if camps.empty?

      out = +"\n### What they produced\n\n"
      camps.sort_by { |_, ps| [-ps.size, ps.first] }.each do |output, ps|
        out << "**#{ps.map { |p| Parsers[p][:label] }.join(', ')}**"

        # The rejection camp gets no block of its own. It compares as one
        # symbol because two parsers refusing the same document agree about
        # the document, and the messages that differ are already in the table
        # above -- reprinting them here would say the same thing twice.
        if output == :error
          out << " — rejected the document.\n"
        else
          out << "\n\n"
          out << fence(render(output), probe.mode == :value ? 'json' : nil)
        end

        # One blank line after every camp, whichever branch wrote it, so the
        # rejection camp does not butt up against the next heading.
        out << "\n"
      end
      out.sub(/\n+\z/, "\n")
    end

    # --- the index -----------------------------------------------------------

    def index(ids, probes)
      out = +"# Custom cases\n\n"
      out << "Local documents from `data/custom_cases/`, run against every parser.\n\n"
      out << "These carry no expectation. The suite states what a parser should build\n"
      out << "and this harness scores against it; a custom case asks the weaker question\n"
      out << "of what each parser *does*, with no claim about which answer is right.\n"
      out << "Nothing here is a pass or a failure, and nothing here enters the pass\n"
      out << "rates in the scored reports — those are a number against a fixed published\n"
      out << "corpus, and adding local cases to it would make them mean something\n"
      out << "different in this checkout than anywhere else.\n\n"
      out << "#{ids.size} case#{'s' unless ids.size == 1}, "
      out << "#{probes.map { |p| p.parsers.size }.max} parsers.\n\n"

      head = ['case', 'name'] + probes.map { |p| "#{p.mode} camps" }

      # Most-contested first: a document the field splits four ways is the
      # reason to keep a custom corpus at all.
      rows = ids.sort_by { |id| [-probes.sum { |p| p.camps(id).size }, id] }.map do |id|
        kase = probes.filter_map { |p| p.cases_by_id[id] }.first
        [
          "[`#{id}`](#{filename(id)}.md)",
          inline(kase&.label),
          *probes.map { |p| p.camps(id).size.to_s }
        ]
      end

      out << Report.md_table(head, rows)
      out << "\nA case with one camp is a document every parser handled the same way.\n"
      out << "More than one is a disagreement, and the case's page says who is on\n"
      out << "which side.\n"
      out
    end

    def as_json(ids, probes)
      {
        generated_at: Time.now.utc.iso8601,
        source: CustomCases::DIR.sub("#{Config::ROOT}/", ''),
        scored: false,
        note: 'Custom cases carry no expectation and are excluded from every ' \
              'pass rate in the scored reports.',
        case_count: ids.size,
        runs: probes.map do |probe|
          {
            mode: probe.mode,
            duration_seconds: probe.duration&.round(1),
            parsers: probe.parsers.map do |p|
              { id: p, label: Parsers[p][:label], language: Parsers[p][:lang],
                version: probe.versions[p] }
            end,
            cases: probe.case_ids.map do |id|
              camps = probe.camps(id)
              {
                case: id,
                camps: camps.size,
                observations: probe.parsers.filter_map do |p|
                  o = probe.for(p, id)
                  next if o.nil?

                  { parser: p, outcome: o.outcome, output: o.output }
                end
              }
            end
          }
        end
      }
    end

    # --- shared bits ---------------------------------------------------------

    private

    def outcome_label(obs)
      return 'no output' if obs.nil?

      { ok: 'parsed', error: 'rejected', no_output: 'no output' }
        .fetch(obs.outcome, obs.outcome.to_s)
    end

    # Parsed first, rejected second, broken last -- so the table reads as a
    # split rather than as a ranking. Neither end of it is "better"; with no
    # expectation, rejecting a document is a legitimate answer.
    def outcome_order(obs)
      return 9 if obs.nil?

      { ok: 0, error: 1, no_output: 2 }.fetch(obs.outcome, 8)
    end

    # A one-line description for the table. The full output is below it.
    def summary(obs)
      return 'the runner got nothing back (timeout, or the container failed)' if obs.nil?

      case obs.outcome
      when :error then obs.output.to_s
      when :no_output then 'the runner got nothing back (timeout, or the container failed)'
      else summarize_ok(obs)
      end
    end

    def summarize_ok(obs)
      out = obs.output
      return JSON.generate(out) unless out.is_a?(Array) && out.all?(String)

      body = out.reject { |l| l.start_with?('+STR', '-STR', '+DOC', '-DOC') }
      return 'an empty document' if body.empty?

      kind = case body.first
             when /\A\+MAP/ then 'a mapping'
             when /\A\+SEQ/ then 'a sequence'
             when /\A=VAL/ then "the scalar #{body.first.sub(/\A=VAL\s*/, '').inspect}"
             else body.first
             end
      "#{kind} (#{body.size} event#{'s' unless body.size == 1})"
    end

    def render(output)
      return output.map { |l| text(l) }.join("\n") if output.is_a?(Array) && output.all?(String)

      JSON.pretty_generate(output)
    rescue StandardError
      output.inspect
    end

    # Custom cases are read as binary on purpose -- a case is quite likely to be
    # about an encoding or a stray control character, and transcoding on the way
    # in would quietly fix the thing being tested. The report is UTF-8 text,
    # though, so the bytes have to be labelled before they can be concatenated
    # into it, and a case holding bytes that are not valid UTF-8 must render as
    # something rather than take the whole run down.
    #
    # `scrub` replaces those bytes with U+FFFD. That loses information, but the
    # document itself is still on disk in data/custom_cases/ intact, and the
    # alternative is a report that cannot be written at all.
    def text(bytes)
      s = bytes.to_s
      return s if s.encoding == Encoding::UTF_8 && s.valid_encoding?

      s.dup.force_encoding(Encoding::UTF_8).scrub
    end

    # Fenced so a document containing backticks, or an event stream containing
    # a pipe, does not break out of the block.
    def fence(text, lang = nil)
      body = text.to_s
      ticks = '`' * [4, (body.scan(/`+/).map(&:length).max || 0) + 1].max
      "#{ticks}#{lang}\n#{body}\n#{ticks}\n"
    end

    # Parameter is `raw`, not `text`: `text` is the encoding helper above, and a
    # parameter of that name would shadow it inside exactly the method that
    # needs it.
    def inline(raw, limit: 150)
      return '' if raw.nil?

      s = text(raw).gsub(/\s+/, ' ').strip
      s = "#{s[0, limit - 1].rstrip}…" if s.length > limit
      s.gsub('|', '\\|')
    end
  end
end

require_relative 'custom_cases'
