# frozen_string_literal: true

require 'fileutils'
require 'json'
require_relative 'config'
require_relative 'parsers'
require_relative 'report'

# One file per failing case, under reports/cases/.
#
# The other reports are organized by parser: how many cases each one failed,
# and in what way. This is the transpose -- a single case, with every parser's
# verdict on it side by side, the document that produced them, and what the
# suite expected. It is the view you want when a case id turns up in a bug
# report or a changelog and the question is "who gets this wrong, and what do
# they do instead", which the summary tables can only answer a column at a time.
#
# Only failing cases get a file. Most of the suite passes everywhere, and
# writing those out would bury the cases that do not.
module CaseReport
  # Both runs land in the same file rather than one file per mode.
  #
  # A case that fails the event run and passes the value run is a specific,
  # interesting thing -- the parser built the wrong stream and still resolved
  # the right object -- and splitting the two into separate directories would
  # hide exactly that. So `write_all` takes every run at once and sections the
  # file by mode.
  class << self
    def write_all(runs, dir: Config::REPORT_DIR)
      runs = Array(runs).reject { |r| r.nil? }
      return {} if runs.empty?

      cases_dir = File.join(dir, 'cases')
      FileUtils.mkdir_p(cases_dir)

      # Clear the previous run's files so a case that starts passing stops
      # having a page. Scoped to the .md files this writes rather than an rm_rf
      # of the directory, since --out can point anywhere.
      Dir.glob(File.join(cases_dir, '*.md')).each { |f| File.delete(f) }

      ids = runs.flat_map(&:failing_case_ids).uniq.sort
      written = ids.to_h do |id|
        path = File.join(cases_dir, "#{filename(id)}.md")
        File.write(path, page(id, runs))
        [id, path]
      end

      File.write(File.join(cases_dir, 'README.md'), index(ids, runs))
      written
    end

    # `4MUZ#0` is a legal case id and an awkward filename: `#` is a fragment
    # separator in a URL and a comment character in half the shells that might
    # glob this directory. Bare ids never contain a dash, so the substitution
    # stays reversible.
    def filename(case_id) = case_id.tr('#', '-')

    # --- one case ------------------------------------------------------------

    def page(id, runs)
      kase = runs.filter_map { |r| r.cases_by_id[id] }.first

      out = +"# #{id}"
      out << " — #{kase.label}" if kase&.label && !kase.label.to_s.strip.empty?
      out << "\n\n"
      out << meta_lines(id, kase, runs)
      out << source_section(kase) if kase
      runs.each { |run| out << run_section(id, run) }
      out
    end

    def meta_lines(id, kase, runs)
      out = +''
      out << "- suite: `#{Config::SUITE_REF}`\n"
      out << "- tags: #{kase.tags.map { |t| "`#{t}`" }.join(' ')}\n" if kase && !kase.tags.empty?
      out << "- expected: #{expectation(kase)}\n" if kase

      # Which of the two runs even looked at this case. A case with no `json:`
      # sits out the value run entirely, and saying so is better than leaving a
      # reader to wonder why one section is missing.
      scored = runs.select { |r| r.case_ids.include?(id) }.map { |r| "`#{r.mode}`" }
      out << "- scored in: #{scored.join(', ')}\n" unless scored.empty?
      out << "\n"
    end

    def expectation(kase)
      return 'the suite marks this document **ill-formed**; a parser must reject it' if kase.error?
      return 'a valid document, with an event stream and a JSON value' if kase.value?

      'a valid document, with an event stream but no JSON projection'
    end

    def source_section(kase)
      out = +"## Document\n\n"
      out << fence(kase.yaml.to_s, 'yaml')

      unless kase.error?
        if kase.events
          out << "\nExpected events:\n\n"
          out << fence(kase.events.join("\n"))
        end
        if kase.json
          out << "\nExpected value:\n\n"
          out << fence(kase.json.to_s.strip, 'json')
        end
      end
      out
    end

    # One section per run: who passed, then a line per parser that did not.
    def run_section(id, run)
      rows = run.parsers.map { |p| [p, run.index[[id, p]]] }
      return '' if rows.all? { |_, r| r.nil? }

      passed, failed = rows.partition { |_, r| r&.pass? }

      out = +"\n## #{run.title || run.mode}\n\n"

      # A case can fail one run and pass the other -- the parser built the
      # wrong events and still resolved the right object, or vice versa. That
      # contrast is worth a line of its own, so the clean run is stated rather
      # than left out.
      if failed.empty?
        out << "Every parser passed this case here; it is in this directory for the other run.\n"
        return out
      end

      out << "#{failed.size} of #{run.parsers.size} parsers failed this case.\n\n"

      # Worst kind first, matching the column order of the summary tables.
      out << Report.md_table(
        ['parser', 'verdict', 'what happened'],
        failed.sort_by { |p, r| [Report::KINDS.index(r.status) || 9, p] }
              .map { |p, r| [Parsers[p][:label], Report::KIND_LABEL[r.status], inline(r.detail)] }
      )

      out << "\nPassed: #{passed.map { |p, _| Parsers[p][:label] }.join(', ')}\n" unless passed.empty?

      # What each camp actually produced, once per distinct output rather than
      # once per parser. Nine parsers failing a case usually means two or three
      # distinct wrong answers, and printing the same stream nine times would
      # make the file unreadable for no added information.
      out << outputs_section(id, run, failed.map(&:first))
      out
    end

    def outputs_section(id, run, parser_ids)
      camps = Hash.new { |h, k| h[k] = [] }
      parser_ids.each do |p|
        o = run.output_for(p, id)
        camps[o] << p unless o.nil?
      end
      return '' if camps.empty?

      out = +"\n### What they produced\n\n"
      camps.sort_by { |_, ps| [-ps.size, ps.first] }.each do |output, ps|
        out << "**#{ps.map { |p| Parsers[p][:label] }.join(', ')}**"
        if output == :error
          out << " — rejected the document.\n\n"
          next
        end
        out << "\n\n"
        out << fence(render(output), run.mode == :value ? 'json' : nil)
      end
      out
    end

    def render(output)
      return output.join("\n") if output.is_a?(Array) && output.all?(String)

      JSON.pretty_generate(output)
    rescue StandardError
      output.inspect
    end

    # --- the index -----------------------------------------------------------

    def index(ids, runs)
      out = +"# Failing cases\n\n"
      out << "One file per case that at least one parser got wrong, with every\n"
      out << "parser's verdict on it and the output each one produced.\n\n"
      out << "Suite `#{Config::SUITE_REF}`; #{ids.size} of #{runs.map(&:case_count).max} cases have a file.\n\n"

      counts = Hash.new { |h, k| h[k] = Hash.new(0) }
      runs.each do |run|
        run.failures.each { |r| counts[r.case_id][run.mode] += 1 }
      end

      head = ['case', 'name'] + runs.map { |r| "#{r.mode} failures" }

      # Worst first: a case every parser disagrees on says more about YAML than
      # a case one parser has a bug in.
      rows = ids.sort_by { |id| [-runs.sum { |r| counts[id][r.mode] }, id] }.map do |id|
        kase = runs.filter_map { |r| r.cases_by_id[id] }.first
        [
          "[`#{id}`](#{filename(id)}.md)",
          inline(kase&.label),
          *runs.map { |r| counts[id][r.mode].zero? ? '·' : counts[id][r.mode].to_s }
        ]
      end

      out << Report.md_table(head, rows)
      out
    end

    # --- shared bits ---------------------------------------------------------

    private

    # Fenced so a document containing backticks, or an event stream containing
    # a pipe, does not break out of the block. Four backticks clears any
    # ordinary fence inside the content.
    def fence(text, lang = nil)
      body = text.to_s
      ticks = '`' * [4, (body.scan(/`+/).map(&:length).max || 0) + 1].max
      "#{ticks}#{lang}\n#{body}\n#{ticks}\n"
    end

    # Table cells cannot hold a newline or an unescaped pipe. The pipe is
    # escaped rather than substituted: these cells quote parser output, and a
    # `|` swapped for a `/` silently changes the document being reported on.
    #
    # Capped, because a value-run detail spells out the whole got-and-want pair
    # and the "what they produced" block below the table already shows it in
    # full. What the table is for is telling the rows apart at a glance.
    def inline(text, limit: 150)
      return '' if text.nil?

      s = text.to_s.gsub(/\s+/, ' ').strip
      s = "#{s[0, limit - 1].rstrip}…" if s.length > limit
      s.gsub('|', '\\|')
    end
  end
end
