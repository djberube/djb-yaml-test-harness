# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'config'
require_relative 'parsers'

# Turns a run's results into the report formats.
#
# Four outputs, because they answer different questions:
#
#   summary   how many of each failure kind, per parser -- the headline
#   matrix    which parsers agree on which case -- the cross-tab
#   detail    what exactly went wrong on one case -- the debugging view
#   json      the same data, for anything downstream
#
# Terminal output is the summary plus a matrix of failures only; the files
# carry everything.
module Report
  # Ordered so the columns read worst-to-least-ambiguous, which is also
  # roughly the order a reader cares about: silently wrong beats loudly wrong.
  KINDS = %i[accepts_invalid wrong_events rejects_valid harness_error].freeze

  KIND_LABEL = {
    pass: 'pass',
    accepts_invalid: 'accepts-invalid',
    wrong_events: 'wrong-events',
    rejects_valid: 'rejects-valid',
    harness_error: 'harness-error'
  }.freeze

  KIND_BLURB = {
    accepts_invalid: 'parsed a document the suite marks ill-formed',
    wrong_events: 'parsed, but produced a different event stream',
    rejects_valid: 'raised on a document the suite marks valid',
    harness_error: 'the runner failed; not a parser verdict'
  }.freeze

  Run = Struct.new(:results, :parsers, :versions, :case_count, :started_at,
                   :finished_at, :suite_ref, keyword_init: true) do
    # results grouped by parser, then counted by status.
    def tally
      parsers.to_h do |p|
        rows = results.select { |r| r.parser == p }
        counts = Hash.new(0)
        rows.each { |r| counts[r.status] += 1 }
        [p, counts]
      end
    end

    def failures = results.reject(&:pass?)

    # Case ids that at least one parser failed, in suite order.
    def failing_case_ids
      failures.map(&:case_id).uniq.sort
    end

    def duration
      return nil unless started_at && finished_at

      finished_at - started_at
    end
  end

  class << self
    # --- terminal ------------------------------------------------------------

    def terminal(run, io: $stdout, matrix: true)
      io.puts
      io.puts summary_table(run)
      io.puts
      return unless matrix && !run.failing_case_ids.empty?

      io.puts matrix_table(run, only_failures: true)
      io.puts
      io.puts "legend: #{KINDS.map { |k| "#{glyph(k)} #{KIND_LABEL[k]}" }.join('   ')}"
      io.puts
    end

    # The headline: one row per parser, one column per failure kind.
    def summary_table(run)
      tally = run.tally
      total = run.case_count

      head = ['parser', 'pass', 'pass%'] + KINDS.map { |k| KIND_LABEL[k] }
      rows = run.parsers.map do |p|
        counts = tally[p]
        passed = counts[:pass].to_i
        [
          Parsers[p][:label],
          passed.to_s,
          format('%.1f%%', total.zero? ? 0 : 100.0 * passed / total)
        ] + KINDS.map { |k| counts[k].to_i.zero? ? '.' : counts[k].to_s }
      end

      # A parser that fails nothing prints dots, so the eye lands on the
      # columns that actually have numbers in them.
      render_table(head, rows, align: [:left, :right, :right] + KINDS.map { :right })
    end

    # Case x parser, so a row shows whether a failure is one parser's bug or
    # everybody's. Restricted to failing cases by default -- the full grid is
    # 402 rows of mostly dots.
    def matrix_table(run, only_failures: true)
      ids = only_failures ? run.failing_case_ids : run.results.map(&:case_id).uniq.sort
      by_key = run.results.to_h { |r| [[r.case_id, r.parser], r] }

      head = ['case'] + run.parsers.map { |p| short(p) }
      rows = ids.map do |id|
        [id] + run.parsers.map do |p|
          r = by_key[[id, p]]
          r.nil? ? '?' : (r.pass? ? '.' : glyph(r.status))
        end
      end

      render_table(head, rows, align: [:left] + run.parsers.map { :center })
    end

    # --- files ---------------------------------------------------------------

    def write_all(run, dir: Config::REPORT_DIR)
      FileUtils.mkdir_p(dir)
      paths = {
        markdown: File.join(dir, 'report.md'),
        json: File.join(dir, 'report.json'),
        csv: File.join(dir, 'matrix.csv'),
        text: File.join(dir, 'report.txt')
      }
      File.write(paths[:markdown], markdown(run))
      File.write(paths[:json], JSON.pretty_generate(as_json(run)))
      File.write(paths[:csv], csv(run))
      File.write(paths[:text], plain(run))
      paths
    end

    def markdown(run)
      out = +"# YAML parser conformance\n\n"
      out << run_header(run).map { |l| "#{l}  \n" }.join
      out << "\n## Summary\n\n"
      out << md_table(summary_head(run), summary_rows(run))
      out << "\nFailure kinds:\n\n"
      KINDS.each { |k| out << "- **#{KIND_LABEL[k]}** — #{KIND_BLURB[k]}\n" }

      out << "\n## Failures by case\n\n"
      if run.failing_case_ids.empty?
        out << "Every parser passed every case.\n"
      else
        out << "`.` passed · #{KINDS.map { |k| "`#{glyph(k)}` #{KIND_LABEL[k]}" }.join(' · ')}\n\n"
        head = ['case'] + run.parsers.map { |p| short(p) }
        by_key = run.results.to_h { |r| [[r.case_id, r.parser], r] }
        rows = run.failing_case_ids.map do |id|
          [id] + run.parsers.map do |p|
            r = by_key[[id, p]]
            r.nil? ? '?' : (r.pass? ? '.' : glyph(r.status))
          end
        end
        out << md_table(head, rows)
      end

      out << "\n## Detail\n\n"
      run.parsers.each do |p|
        rows = run.results.select { |r| r.parser == p && !r.pass? }
        next if rows.empty?

        out << "### #{Parsers[p][:label]}\n\n"
        rows.sort_by { |r| [KINDS.index(r.status) || 9, r.case_id] }.each do |r|
          out << "- `#{r.case_id}` **#{KIND_LABEL[r.status]}** — #{r.detail}\n"
        end
        out << "\n"
      end
      out
    end

    def as_json(run)
      {
        generated_at: Time.now.utc.iso8601,
        suite_ref: run.suite_ref,
        case_count: run.case_count,
        duration_seconds: run.duration&.round(1),
        parsers: run.parsers.map do |p|
          spec = Parsers[p]
          counts = run.tally[p]
          {
            id: p,
            label: spec[:label],
            language: spec[:lang],
            version: run.versions[p],
            note: spec[:note],
            pass: counts[:pass].to_i,
            pass_rate: run.case_count.zero? ? 0 : (100.0 * counts[:pass].to_i / run.case_count).round(2),
            **KINDS.to_h { |k| [k, counts[k].to_i] }
          }
        end,
        failures: run.failures.map do |r|
          {
            case: r.case_id, parser: r.parser, kind: KIND_LABEL[r.status],
            detail: r.detail, got: r.got, want: r.want
          }
        end
      }
    end

    def csv(run)
      by_key = run.results.to_h { |r| [[r.case_id, r.parser], r] }
      lines = [(['case'] + run.parsers).join(',')]
      run.results.map(&:case_id).uniq.sort.each do |id|
        cells = run.parsers.map do |p|
          r = by_key[[id, p]]
          r.nil? ? 'missing' : (r.pass? ? 'pass' : KIND_LABEL[r.status])
        end
        lines << ([id] + cells).join(',')
      end
      "#{lines.join("\n")}\n"
    end

    def plain(run)
      io = StringIO.new
      run_header(run).each { |l| io.puts l }
      io.puts
      io.puts summary_table(run)
      io.puts
      io.puts matrix_table(run, only_failures: true) unless run.failing_case_ids.empty?
      io.string
    end

    # --- shared bits ---------------------------------------------------------

    private

    def run_header(run)
      lines = [
        "suite: #{run.suite_ref}  (#{run.case_count} cases)",
        "run:   #{run.finished_at&.utc&.iso8601 || Time.now.utc.iso8601}"
      ]
      lines << format('took:  %.1fs', run.duration) if run.duration
      lines << ''
      run.parsers.each do |p|
        lines << format('  %-22s %-10s %s', Parsers[p][:label], Parsers[p][:lang],
                        run.versions[p] || 'unknown')
      end
      lines
    end

    def summary_head(run)
      ['parser', 'language', 'version', 'pass', 'pass %'] + KINDS.map { |k| KIND_LABEL[k] }
    end

    def summary_rows(run)
      tally = run.tally
      run.parsers.map do |p|
        spec = Parsers[p]
        counts = tally[p]
        passed = counts[:pass].to_i
        [
          spec[:label], spec[:lang], run.versions[p] || '?',
          "#{passed}/#{run.case_count}",
          format('%.1f%%', run.case_count.zero? ? 0 : 100.0 * passed / run.case_count)
        ] + KINDS.map { |k| counts[k].to_i.to_s }
      end
    end

    # A single character per failure kind, so the matrix stays narrow enough
    # to read at nine parsers wide.
    def glyph(status)
      { accepts_invalid: 'A', wrong_events: 'W', rejects_valid: 'R',
        harness_error: '!' }.fetch(status, '?')
    end

    # Column headers for the matrix. Full labels would make the grid wider
    # than any terminal, so parsers get a short form.
    def short(parser_id)
      {
        'psych' => 'psych', 'psych-fyaml' => 'fyaml', 'pyyaml' => 'pyyaml',
        'pyyaml-c' => 'pyy-c', 'rapidyaml' => 'ryml', 'js-yaml' => 'jsyaml',
        'go-yaml' => 'go', 'saphyr' => 'saphyr', 'snakeyaml' => 'snake'
      }.fetch(parser_id, parser_id[0, 6])
    end

    def render_table(head, rows, align:)
      widths = head.each_index.map do |i|
        ([head[i]] + rows.map { |r| r[i].to_s }).map(&:length).max
      end

      fmt = lambda do |cells|
        cells.each_with_index.map do |c, i|
          s = c.to_s
          case align[i]
          when :right then s.rjust(widths[i])
          when :center then s.center(widths[i])
          else s.ljust(widths[i])
          end
        end.join('  ').rstrip
      end

      out = [fmt.call(head), widths.map { |w| '-' * w }.join('  ')]
      rows.each { |r| out << fmt.call(r) }
      out.join("\n")
    end

    def md_table(head, rows)
      out = +"| #{head.join(' | ')} |\n"
      out << "|#{head.map { '---' }.join('|')}|\n"
      rows.each { |r| out << "| #{r.join(' | ')} |\n" }
      out
    end
  end
end

require 'fileutils'
require 'stringio'
