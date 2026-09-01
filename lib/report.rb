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
  KINDS = %i[accepts_invalid wrong_events wrong_value rejects_valid harness_error].freeze

  KIND_LABEL = {
    pass: 'pass',
    accepts_invalid: 'accepts-invalid',
    wrong_events: 'wrong-events',
    wrong_value: 'wrong-value',
    rejects_valid: 'rejects-valid',
    harness_error: 'harness-error'
  }.freeze

  KIND_BLURB = {
    accepts_invalid: 'parsed a document the suite marks ill-formed',
    wrong_events: 'parsed, but produced a different event stream',
    wrong_value: 'parsed correctly, but resolved to a different value',
    rejects_valid: 'raised on a document the suite marks valid',
    harness_error: 'the runner failed; not a parser verdict'
  }.freeze

  Run = Struct.new(:results, :parsers, :versions, :case_count, :started_at,
                   :finished_at, :suite_ref, :mode, :title, keyword_init: true) do
    # Only the kinds this run can actually produce. An events run never yields
    # wrong_value and a value run never yields wrong_events, so showing both
    # columns would print a permanently empty one in each.
    def kinds
      KINDS.reject do |k|
        (k == :wrong_value && mode != :value) || (k == :wrong_events && mode == :value)
      end
    end

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

    # --- agreement ------------------------------------------------------------
    #
    # Conformance asks whether a parser matched the suite. Agreement asks
    # whether two parsers matched *each other*, which is a different question
    # with a different answer: two libraries can fail the same case in two
    # different ways, or agree exactly while both being wrong. Neither shows up
    # in a pass/fail tally.
    #
    # This is the practical question behind "will this document survive a trip
    # through another language's parser", which is what a YAML file in a polyglot
    # repo actually has to do.

    # What one parser produced for one case, reduced to a comparable value.
    #
    # A parse error compares as the single symbol :error rather than by message,
    # because two parsers rejecting the same document agree about the document
    # even when their diagnostics read nothing alike.
    def output_for(parser, case_id)
      r = index[[case_id, parser]]
      return nil if r.nil? || r.status == :harness_error

      r.got.nil? ? :error : r.got
    end

    def index
      @index ||= results.to_h { |r| [[r.case_id, r.parser], r] }
    end

    def case_ids
      @case_ids ||= results.map(&:case_id).uniq
    end

    # Cases where both parsers produced something comparable, and how many of
    # those they produced the *same* thing for.
    def agreement(a, b)
      shared = 0
      same = 0
      case_ids.each do |id|
        oa = output_for(a, id)
        ob = output_for(b, id)
        next if oa.nil? || ob.nil?

        shared += 1
        same += 1 if oa == ob
      end
      [same, shared]
    end

    # The full pairwise matrix, as {[a, b] => [same, shared]} for a < b.
    def agreement_pairs
      @agreement_pairs ||= parsers.combination(2).to_h { |a, b| [[a, b], agreement(a, b)] }
    end

    # Cases every parser produced the identical output for. A high count here
    # is the boring majority of YAML; what is left is the interesting part.
    def unanimous_case_ids
      @unanimous_case_ids ||= case_ids.select do |id|
        outs = parsers.map { |p| output_for(p, id) }
        !outs.any?(&:nil?) && outs.uniq.size == 1
      end
    end

    # Cases where the parsers split into two or more camps, with the camps.
    # Returns [id, {output => [parser, ...]}] sorted by how divided the case is.
    def contested
      @contested ||= case_ids.filter_map do |id|
        camps = Hash.new { |h, k| h[k] = [] }
        parsers.each do |p|
          o = output_for(p, id)
          camps[o] << p unless o.nil?
        end
        next if camps.size < 2

        [id, camps]
      end.sort_by { |id, camps| [-camps.size, id] }
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
      io.puts "legend: #{run.kinds.map { |k| "#{glyph(k)} #{KIND_LABEL[k]}" }.join('   ')}"
      io.puts
    end

    # Agreement is reported after conformance because it answers the second
    # question, not because it matters less: a parser can be conformant and
    # still be the odd one out, and vice versa.
    def terminal_agreement(run, io: $stdout)
      total = run.case_ids.size
      unanimous = run.unanimous_case_ids.size

      io.puts
      io.puts "agreement — how often two parsers produced the same output, not whether it was right"
      io.puts
      io.puts agreement_table(run)
      io.puts
      io.puts format('  all %d parsers identical on %d/%d cases (%.1f%%); %d contested',
                     run.parsers.size, unanimous, total,
                     total.zero? ? 0 : 100.0 * unanimous / total,
                     run.contested.size)
      io.puts
      return if run.contested.empty?

      io.puts contested_lines(run)
      io.puts
    end

    # A grid of pairwise agreement percentages.
    #
    # The diagonal is left blank rather than filled with 100%: a parser agreeing
    # with itself is not information, and an unbroken diagonal of the same
    # number makes the grid harder to scan.
    def agreement_table(run)
      pairs = run.agreement_pairs
      head = ['parser'] + run.parsers.map { |p| short(p) }

      rows = run.parsers.map do |a|
        cells = run.parsers.map do |b|
          next '.' if a == b

          same, shared = pairs[[a, b]] || pairs[[b, a]]
          shared.to_i.zero? ? '-' : format('%.0f', 100.0 * same / shared)
        end
        [short(a)] + cells
      end

      render_table(head, rows, align: [:left] + run.parsers.map { :right })
    end

    # The cases the parsers split on, with who is in which camp.
    #
    # Capped, because the full list is long and the top of it is the part worth
    # reading: a case that splits the field three or four ways is a corner of
    # the spec nobody agrees on, which is more interesting than the many cases
    # where one parser stands alone.
    def contested_lines(run, limit: 15)
      rows = run.contested.first(limit).map do |id, camps|
        groups = camps.sort_by { |_, ps| [-ps.size, ps.first] }.map do |out, ps|
          "#{camp_label(out, camps)}: #{ps.map { |p| short(p) }.join(' ')}"
        end
        [id, camps.size.to_s, groups.join('  |  ')]
      end

      render_table(%w[case camps split], rows, align: %i[left right left])
    end

    # Names a camp so two camps on the same case are told apart.
    #
    # "parsed" alone is useless when every camp parsed and they merely disagree
    # about the result, which is the most interesting kind of split. Naming the
    # first line the outputs differ on says what the disagreement is about.
    def camp_label(out, camps)
      return 'error' if out == :error
      return 'parsed' if camps.size < 2

      others = camps.keys.reject { |o| o.equal?(out) }
      ref = others.find { |o| o != :error }
      return 'parsed' if ref.nil?

      # An events run compares arrays of event lines, so the first line the two
      # differ on names the disagreement precisely. A value run compares parsed
      # JSON, where there is no line to point at -- the rendered value is the
      # most specific thing available.
      return out.inspect[0, 28] unless out.is_a?(Array) && ref.is_a?(Array)

      i = out.each_index.find { |n| out[n] != ref[n] } || [out.size, ref.size].min
      line = out[i]
      line.nil? ? "ends at #{i}" : line.to_s[0, 28]
    end

    # The headline: one row per parser, one column per failure kind.
    def summary_table(run)
      tally = run.tally
      total = run.case_count

      kinds = run.kinds
      head = ['parser', 'pass', 'pass%'] + kinds.map { |k| KIND_LABEL[k] }
      rows = run.parsers.map do |p|
        counts = tally[p]
        passed = counts[:pass].to_i
        [
          Parsers[p][:label],
          passed.to_s,
          format('%.1f%%', total.zero? ? 0 : 100.0 * passed / total)
        ] + kinds.map { |k| counts[k].to_i.zero? ? '.' : counts[k].to_s }
      end

      # A parser that fails nothing prints dots, so the eye lands on the
      # columns that actually have numbers in them.
      render_table(head, rows, align: [:left, :right, :right] + kinds.map { :right })
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

    # `suffix` keeps two runs of the same cases from overwriting each other
    # when both the event and value scores are written in one invocation.
    def write_all(run, dir: Config::REPORT_DIR, suffix: nil)
      FileUtils.mkdir_p(dir)
      paths = {
        markdown: File.join(dir, "report#{suffix}.md"),
        json: File.join(dir, "report#{suffix}.json"),
        csv: File.join(dir, "matrix#{suffix}.csv"),
        text: File.join(dir, "report#{suffix}.txt")
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
      run.kinds.each { |k| out << "- **#{KIND_LABEL[k]}** — #{KIND_BLURB[k]}\n" }

      out << "\n## Agreement\n\n"
      out << "How often two parsers produced the same output — not whether it was right.\n"
      out << "A pair can agree on a wrong answer, and two parsers can both fail a case\n"
      out << "while disagreeing about how.\n\n"
      out << md_table(['', *run.parsers.map { |p| short(p) }],
                      run.parsers.map do |a|
                        [short(a)] + run.parsers.map do |b|
                          next '—' if a == b

                          same, shared = run.agreement_pairs[[a, b]] || run.agreement_pairs[[b, a]]
                          shared.to_i.zero? ? '-' : format('%.0f%%', 100.0 * same / shared)
                        end
                      end)
      out << format("\nAll %d parsers produced identical output on %d of %d cases (%.1f%%).\n",
                    run.parsers.size, run.unanimous_case_ids.size, run.case_ids.size,
                    run.case_ids.empty? ? 0 : 100.0 * run.unanimous_case_ids.size / run.case_ids.size)

      unless run.contested.empty?
        out << "\n### Contested cases\n\n"
        out << "Sorted by how many ways the field split.\n\n"
        out << md_table(%w[case camps split], run.contested.first(40).map do |id, camps|
          groups = camps.sort_by { |_, ps| [-ps.size, ps.first] }.map do |o, ps|
            "#{camp_label(o, camps)}: #{ps.map { |p| short(p) }.join(' ')}"
          end
          [format('`%s`', id), camps.size.to_s, groups.join(' · ')]
        end)
      end

      out << "\n## Failures by case\n\n"
      if run.failing_case_ids.empty?
        out << "Every parser passed every case.\n"
      else
        out << "`.` passed · #{run.kinds.map { |k| "`#{glyph(k)}` #{KIND_LABEL[k]}" }.join(' · ')}\n\n"
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
        scored: run.mode,
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
            **run.kinds.to_h { |k| [k, counts[k].to_i] }
          }
        end,
        failures: run.failures.map do |r|
          {
            case: r.case_id, parser: r.parser, kind: KIND_LABEL[r.status],
            detail: r.detail, got: r.got, want: r.want
          }
        end,
        agreement: {
          unanimous: run.unanimous_case_ids,
          contested: run.contested.map do |id, camps|
            {
              case: id,
              camps: camps.map { |out, ps| { parsers: ps, error: out == :error } }
            }
          end,
          pairs: run.agreement_pairs.map do |(a, b), (same, shared)|
            {
              a: a, b: b, same: same, shared: shared,
              rate: shared.zero? ? nil : (100.0 * same / shared).round(2)
            }
          end
        },
        # Every row, passes included, with what the parser actually produced.
        #
        # The failures list above answers "was it right"; this answers "what
        # did it say", which is a different question and not derivable from the
        # first. Two parsers can fail the same case with different output, and
        # two can agree exactly while both being wrong -- neither shows up in a
        # pass/fail tally. Agreement statistics are computed from here.
        results: run.results.map do |r|
          {
            case: r.case_id, parser: r.parser, kind: KIND_LABEL[r.status],
            got: r.got
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
        "scored: #{run.title || run.mode}",
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
      ['parser', 'language', 'version', 'pass', 'pass %'] + run.kinds.map { |k| KIND_LABEL[k] }
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
        ] + run.kinds.map { |k| counts[k].to_i.to_s }
      end
    end

    # A single character per failure kind, so the matrix stays narrow enough
    # to read at nine parsers wide.
    def glyph(status)
      { accepts_invalid: 'A', wrong_events: 'W', wrong_value: 'V',
        rejects_valid: 'R', harness_error: '!' }.fetch(status, '?')
    end

    # Column headers for the matrix. Full labels would make the grid wider
    # than any terminal, so parsers get a short form.
    def short(parser_id)
      {
        'psych' => 'psych', 'psych-fyaml' => 'fyaml', 'pyyaml' => 'pyyaml',
        'pyyaml-c' => 'pyy-c', 'rapidyaml' => 'ryml', 'js-yaml' => 'jsyaml',
        'go-yaml' => 'go', 'saphyr' => 'saphyr', 'snakeyaml' => 'snake'
      }.fetch(parser_id) { matrix_short(parser_id) }
    end

    # Matrix ids share long prefixes (libyaml-0.2.1 and libyaml-0.2.2 differ in
    # the last character), so a blind truncation would collide. Keep the part
    # that actually varies.
    def matrix_short(parser_id)
      case parser_id
      when /\Apsych-(\d[\d.]*)\z/ then "p#{Regexp.last_match(1)}"
      when /\Alibyaml-([\d.]+)\z/ then "ly#{Regexp.last_match(1).delete_prefix('0.')}"
      when /\Aruby-([\d.]+)\z/ then "rb#{Regexp.last_match(1)}"
      else parser_id[0, 6]
      end
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
