# frozen_string_literal: true

require 'open3'
require 'timeout'
require 'json'
require 'strscan'
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
  #   :wrong_value     parsed correctly, but resolved to a different value
  #   :harness_error   the runner itself failed; not a parser verdict
  #
  # :wrong_events belongs to the event run and :wrong_value to the value run;
  # no result carries both, because a run scores one question at a time.
  Result = Struct.new(:case_id, :parser, :status, :detail, :got, :want, keyword_init: true) do
    def pass? = status == :pass
    def fail? = !pass? && status != :harness_error
  end

  # What one parser did with one *unjudged* document, from the custom corpus.
  #
  # Deliberately not a Result. A Result carries a `status` that is a verdict
  # against the suite, and these documents have no expectation to be judged
  # against -- reusing the struct would leave a verdict field that either lies
  # or is permanently nil. The three outcomes here are the parser's own, not
  # this harness's opinion of them:
  #
  #   :ok       parsed; `output` is the event stream, or the loaded value
  #   :error    refused the document; `output` is its message
  #   :no_output the runner got nothing back, usually a timeout
  Observation = Struct.new(:case_id, :parser, :outcome, :output, :mode,
                           keyword_init: true) do
    def ok? = outcome == :ok
    def error? = outcome == :error

    # The comparable form, matching Report::Run#output_for: a rejection
    # compares as the bare symbol :error, because two parsers refusing the same
    # document agree about the document even when their messages read nothing
    # alike.
    def comparable
      return nil if outcome == :no_output

      outcome == :error ? :error : output
    end
  end

  class << self
    # Runs every case through one parser, in batches.
    #
    # Yields each Result as it is decided so a caller can show progress; also
    # returns them all.
    # `mode` is :events (compare against the suite's tree:) or :value (compare
    # the loaded object against its json:). They are separate runs over the
    # same cases because they answer separate questions -- a parser can build
    # the right events and then resolve them to the wrong object.
    def run(parser_name, cases, mode: :events, &progress)
      spec = Parsers[parser_name] or raise ArgumentError, "unknown parser #{parser_name}"
      raise ArgumentError, "#{parser_name} cannot score values" if mode == :value && !spec[:value]

      Docker.ensure_image(spec[:dir], spec[:tag], dockerfile: spec[:dockerfile])

      results = []
      cases.each_slice(Config::BATCH_SIZE) do |batch|
        emitted = invoke(spec, batch, mode)
        batch.each do |kase|
          r = mode == :value ? judge_value(parser_name, kase, emitted[kase.id])
                             : judge(parser_name, kase, emitted[kase.id])
          results << r
          progress&.call(r)
        end
      end
      results
    end

    # The parser's self-reported version, for the report header.
    def version(parser_name)
      spec = Parsers[parser_name]
      Docker.ensure_image(spec[:dir], spec[:tag], dockerfile: spec[:dockerfile])
      out, status = Open3.capture2e(
        *Docker.run_argv(spec[:tag], Dir.tmpdir, spec[:version_cmd])
      )
      status.success? ? out.strip.lines.last.to_s.strip : 'unknown'
    rescue StandardError
      'unknown'
    end

    # What a parser does with a document nobody has stated an expectation for.
    #
    # `run` above answers "was it right", which needs an oracle. This answers
    # "what did it say", which does not -- it returns the parser's own outcome
    # with no comparison at all. That is what the custom corpus in
    # data/custom_cases needs: those documents carry no `tree:` and no `json:`,
    # so there is nothing to judge them against, and inventing a verdict would
    # be asserting a right answer this harness does not have.
    #
    # Returns {case_id => Observation}.
    def probe(parser_name, cases, mode: :events)
      spec = Parsers[parser_name] or raise ArgumentError, "unknown parser #{parser_name}"
      raise ArgumentError, "#{parser_name} cannot load values" if mode == :value && !spec[:value]

      Docker.ensure_image(spec[:dir], spec[:tag], dockerfile: spec[:dockerfile])

      out = {}
      cases.each_slice(Config::BATCH_SIZE) do |batch|
        emitted = invoke(spec, batch, mode)
        batch.each do |kase|
          out[kase.id] = observe(parser_name, kase, emitted[kase.id], mode)
          yield out[kase.id] if block_given?
        end
      end
      out
    end

    private

    # One container invocation for a batch of cases. Returns id => raw output.
    def invoke(spec, batch, mode = :events)
      payload = +''
      batch.each do |kase|
        bytes = kase.yaml.dup.force_encoding(Encoding::BINARY)
        payload << kase.id << "\n" << bytes.bytesize.to_s << "\n" << bytes
      end
      payload << ".\n"

      cmd = mode == :value ? spec[:cmd] + ['--json'] : spec[:cmd]
      argv = Docker.run_argv(spec[:tag], Dir.tmpdir, cmd)
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

    # Turns a raw emitter section into an Observation, with no comparison.
    def observe(parser_name, kase, emitted, mode)
      mk = ->(outcome, output) do
        Observation.new(case_id: kase.id, parser: parser_name,
                        outcome: outcome, output: output, mode: mode)
      end

      return mk.call(:no_output, nil) if emitted.nil?
      return mk.call(:error, emitted[:lines].first.to_s.strip) unless emitted[:ok]

      if mode == :value
        # The value run's output is one JSON line. Parsed here so the report
        # can render and compare structures rather than strings, where two
        # emitters differing only in key order would look like a disagreement.
        begin
          return mk.call(:ok, JSON.parse(emitted[:lines].first.to_s))
        rescue JSON::ParserError
          return mk.call(:ok, emitted[:lines].first.to_s)
        end
      end

      mk.call(:ok, emitted[:lines].map(&:rstrip).reject(&:empty?))
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

    # The value run: compare the loaded object against the suite's json:.
    #
    # Only cases with a json: are scored. The suite omits it where a document
    # has no meaningful JSON projection, and treating "no expectation" as a
    # pass would inflate every parser by the same ~130 cases.
    def judge_value(parser_name, kase, emitted)
      mk = ->(status, detail, got = nil) do
        Result.new(case_id: kase.id, parser: parser_name, status: status,
                   detail: detail, got: got, want: kase.json)
      end

      return mk.call(:harness_error, 'no output from runner') if emitted.nil?

      if kase.error?
        return mk.call(:pass, emitted[:lines].first.to_s.strip) unless emitted[:ok]

        return mk.call(:accepts_invalid, "loaded #{emitted[:lines].first.to_s.strip[0, 120]}",
                       emitted[:lines].first)
      end

      return mk.call(:rejects_valid, emitted[:lines].first.to_s.strip) unless emitted[:ok]

      want = parse_expected(kase.json)
      return mk.call(:harness_error, "unparseable json: in the suite case") if want.nil?

      got = begin
        JSON.parse(emitted[:lines].first.to_s)
      rescue JSON::ParserError => e
        return mk.call(:harness_error, "emitter produced invalid json: #{e.message[0, 80]}")
      end

      return mk.call(:pass, nil, got) if got == want

      mk.call(:wrong_value, value_divergence(got, want), got)
    end

    # The suite's json: field is a stream: one JSON value per YAML document,
    # concatenated. JSON.parse reads a single value, so the stream is split by
    # letting a parser consume as much as it can and continuing from there.
    def parse_expected(text)
      scanner = StringScanner.new(text.to_s)
      docs = []
      loop do
        scanner.skip(/\s+/)
        break if scanner.eos?

        begin
          docs << JSON.parse(scanner.rest, max_nesting: false, quirks_mode: true)
          break
        rescue JSON::ParserError
          # Fall through to the incremental split below.
        end

        consumed = consume_one(scanner.rest)
        return nil if consumed.nil?

        docs << consumed[0]
        scanner.pos += consumed[1]
      end
      docs
    rescue StandardError
      nil
    end

    # Longest-prefix JSON parse. Used only for the handful of multi-document
    # cases, where the values are concatenated with no separator.
    def consume_one(text)
      (1..text.length).each do |len|
        begin
          return [JSON.parse(text[0, len], quirks_mode: true), len]
        rescue JSON::ParserError
          next
        end
      end
      nil
    end

    def value_divergence(got, want)
      if got.is_a?(Array) && want.is_a?(Array) && got.length != want.length
        return "got #{got.length} document(s), want #{want.length}"
      end

      "got #{got.inspect[0, 160]}, want #{want.inspect[0, 160]}"
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
