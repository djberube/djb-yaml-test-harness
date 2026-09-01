# frozen_string_literal: true

require 'open3'
require 'timeout'
require_relative 'config'
require_relative 'docker'
require_relative 'parsers'

# Feeds cases to a parser's container and reads back event streams.
module Runner
  # What one parser did with one case.
  #
  # `status` is the comparison verdict, not the parser's own outcome:
  #   :pass            did what the suite says
  #   :rejects_valid   raised on a document the suite says is valid
  #   :accepts_invalid parsed a document the suite says is ill-formed
  #   :wrong_events    parsed, but produced a different event stream
  #   :harness_error   the runner itself failed; not a parser verdict
  Result = Struct.new(:case_id, :parser, :status, :detail, :got, :want, keyword_init: true) do
    def pass? = status == :pass
    def fail? = !pass? && status != :harness_error
  end

  class << self
    # Runs every case through one parser, in batches.
    #
    # Yields each Result as it is decided so a caller can show progress; also
    # returns them all.
    def run(parser_name, cases, &progress)
      spec = Parsers[parser_name] or raise ArgumentError, "unknown parser #{parser_name}"
      Docker.ensure_image(spec[:dir], spec[:tag])

      results = []
      cases.each_slice(Config::BATCH_SIZE) do |batch|
        emitted = invoke(spec, batch)
        batch.each do |kase|
          r = judge(parser_name, kase, emitted[kase.id])
          results << r
          progress&.call(r)
        end
      end
      results
    end

    # The parser's self-reported version, for the report header.
    def version(parser_name)
      spec = Parsers[parser_name]
      Docker.ensure_image(spec[:dir], spec[:tag])
      out, status = Open3.capture2e(
        *Docker.run_argv(spec[:tag], Dir.tmpdir, spec[:version_cmd])
      )
      status.success? ? out.strip.lines.last.to_s.strip : 'unknown'
    rescue StandardError
      'unknown'
    end

    private

    # One container invocation for a batch of cases. Returns id => raw output.
    def invoke(spec, batch)
      payload = +''
      batch.each do |kase|
        bytes = kase.yaml.dup.force_encoding(Encoding::BINARY)
        payload << kase.id << "\n" << bytes.bytesize.to_s << "\n" << bytes
      end
      payload << ".\n"

      argv = Docker.run_argv(spec[:tag], Dir.tmpdir, spec[:cmd])
      out = nil
      begin
        Timeout.timeout(Config::CASE_TIMEOUT * batch.size) do
          out, _err, _st = Open3.capture3(*argv, stdin_data: payload, binmode: true)
        end
      rescue Timeout::Error
        return {}
      end

      split(out.to_s.force_encoding(Encoding::UTF_8).scrub)
    end

    # Splits the concatenated `=== <id> <OK|ERR>` sections back apart.
    def split(text)
      out = {}
      current = nil
      text.split("\n").each do |line|
        if (m = line.match(/\A=== (\S+) (OK|ERR)\z/))
          current = m[1]
          out[current] = { ok: m[2] == 'OK', lines: [] }
        elsif current
          out[current][:lines] << line
        end
      end
      out
    end

    def judge(parser_name, kase, emitted)
      mk = ->(status, detail, got = nil) do
        Result.new(case_id: kase.id, parser: parser_name, status: status,
                   detail: detail, got: got, want: kase.events)
      end

      return mk.call(:harness_error, 'no output from runner') if emitted.nil?

      if kase.error?
        # The suite says this document must be rejected.
        return mk.call(:pass, emitted[:lines].first.to_s.strip) unless emitted[:ok]

        # Say what it built instead of raising. "parsed a document the suite
        # marks invalid" is true of every row in this category and so tells a
        # reader nothing; the shape it produced is the part worth seeing.
        got = emitted[:lines].map(&:rstrip).reject(&:empty?)
        return mk.call(:accepts_invalid, "built #{summarize(got)}", got)
      end

      unless emitted[:ok]
        return mk.call(:rejects_valid, emitted[:lines].first.to_s.strip)
      end

      got = emitted[:lines].map(&:rstrip).reject(&:empty?)
      return mk.call(:pass, nil, got) if kase.events.nil? || got == kase.events

      mk.call(:wrong_events, first_divergence(got, kase.events), got)
    end

    # A one-line description of what a parser built, for the accepts-invalid
    # rows where there is no expected stream to diff against.
    def summarize(events)
      body = events.reject { |l| l.start_with?('+STR', '-STR', '+DOC', '-DOC') }
      return 'an empty document' if body.empty?

      kind = case body.first
             when /\A\+MAP/ then 'a mapping'
             when /\A\+SEQ/ then 'a sequence'
             when /\A=VAL/ then "the scalar #{body.first.sub(/\A=VAL\s*/, '').inspect}"
             else body.first
             end
      "#{kind} (#{body.size} event#{'s' unless body.size == 1})"
    end

    # The first line where the two streams differ, which is almost always the
    # informative one -- everything after it is downstream of the same mistake.
    def first_divergence(got, want)
      [got.length, want.length].max.times do |i|
        g = got[i]
        w = want[i]
        next if g == w

        return "line #{i + 1}: got #{g.inspect}, want #{w.inspect}"
      end
      'streams differ'
    end
  end
end

require 'tmpdir'
