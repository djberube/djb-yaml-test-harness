# frozen_string_literal: true

# Emits the yaml-test-suite event DSL for each document on stdin.
#
# Psych exposes the parse tree rather than the event stream, so the events are
# reconstructed by walking Psych::Nodes. That walk is faithful for everything
# the suite compares -- structure, anchors, tags, and scalar style -- because
# each node carries the properties its originating event did.
#
# Shared by the libyaml and libfyaml images; only the linked C parser differs.
#
# With --json, emits the *loaded value* as canonical JSON instead of the event
# stream. That is a different question about the same parser: the event stream
# is what the parser built, the JSON is what Psych then resolved it to. Psych
# can produce the correct events and still hand back the wrong Ruby object --
# `:foo` becoming a Symbol rather than the string ":foo" is the stock example --
# so the two are scored separately.

require 'yaml'
require 'json'
require 'date'
# Time#iso8601 lives in the time library, not core. Ruby 3.4 happens to have it
# loaded by the time this runs and 3.1 does not, so requiring it explicitly is
# what keeps the two rows comparable.
require 'time'

# --- the event DSL -----------------------------------------------------------
#
# Scalars are written `=VAL <anchor?> <tag?> <style><value>` where style is one
# of : ' " | > for plain, single, double, literal and folded. Escapes follow
# the suite's own convention: \n \t \\ and \r inside the value.
module Emit
  STYLE = {
    Psych::Nodes::Scalar::PLAIN => ':',
    Psych::Nodes::Scalar::SINGLE_QUOTED => "'",
    Psych::Nodes::Scalar::DOUBLE_QUOTED => '"',
    Psych::Nodes::Scalar::LITERAL => '|',
    Psych::Nodes::Scalar::FOLDED => '>'
  }.freeze

  def self.escape(str)
    str.gsub('\\', '\\\\\\\\')
       .gsub("\n", '\\n').gsub("\t", '\\t').gsub("\r", '\\r')
       .gsub("\b", '\\b').gsub("\f", '\\f').gsub("\v", '\\v')
       .gsub("\0", '\\0').gsub("\a", '\\a').gsub("\e", '\\e')
  end

  # Anchor and tag, in the order and spacing the suite uses.
  def self.props(node)
    out = +''
    out << " &#{node.anchor}" if node.respond_to?(:anchor) && node.anchor && !node.anchor.empty?
    out << " <#{node.tag}>" if node.respond_to?(:tag) && node.tag && !node.tag.empty?
    out
  end

  def self.walk(node, out)
    case node
    when Psych::Nodes::Stream
      out << '+STR'
      node.children.each { |c| walk(c, out) }
      out << '-STR'
    when Psych::Nodes::Document
      # An explicit `---` is reported as `+DOC ---`; an implicit document is
      # bare. The suite distinguishes them, so this cannot be simplified away.
      out << (node.implicit ? '+DOC' : '+DOC ---')
      node.children.each { |c| walk(c, out) }
      out << (node.implicit_end ? '-DOC' : '-DOC ...')
    when Psych::Nodes::Mapping
      # The suite records collection style before the node's properties: a flow
      # mapping with an anchor is `+MAP {} &a`, not `+MAP &a {}`. Same for
      # sequences with `[]`. Block collections carry no style marker.
      out << "+MAP#{node.style == Psych::Nodes::Mapping::FLOW ? ' {}' : ''}#{props(node)}"
      node.children.each { |c| walk(c, out) }
      out << '-MAP'
    when Psych::Nodes::Sequence
      out << "+SEQ#{node.style == Psych::Nodes::Sequence::FLOW ? ' []' : ''}#{props(node)}"
      node.children.each { |c| walk(c, out) }
      out << '-SEQ'
    when Psych::Nodes::Scalar
      out << "=VAL#{props(node)} #{STYLE.fetch(node.style, ':')}#{escape(node.value)}"
    when Psych::Nodes::Alias
      out << "=ALI *#{node.anchor}"
    else
      raise "unhandled node #{node.class}"
    end
    out
  end

  def self.events(yaml)
    walk(Psych.parse_stream(yaml), [])
  end
end

# --- the loaded-value projection ---------------------------------------------
#
# The suite states expected values as JSON, so a comparison has to project
# Ruby onto JSON's type set. The projection is deliberately lossy in one
# direction only: anything JSON cannot represent is rendered in a form that
# will not accidentally equal a correct answer.
module Value
  # Psych resolves YAML 1.1 types that JSON has no notion of. Rendering a Date
  # as its ISO string is what the suite's own json field expects for
  # timestamp cases, and a Symbol as ":foo" is what makes the Symbol coercion
  # visible as a difference rather than hiding it behind a to_s that happens to
  # match.
  def self.project(obj)
    case obj
    when Hash
      obj.to_h { |k, v| [project_key(k), project(v)] }
    when Array
      obj.map { |v| project(v) }
    when Symbol
      # A Symbol here is Psych resolving `:foo` to :foo where the suite expects
      # the *string* ":foo". Rendering it as ":foo" would make the projection
      # launder the bug into a pass, so it is tagged: JSON has no symbol type,
      # and a parser that returns one has not returned what the suite asked for.
      "#<Symbol :#{obj}>"
    when Date, Time
      obj.iso8601
    when Psych::Omap
      obj.map { |k, v| { project_key(k) => project(v) } }
    when Psych::Set
      obj.keys.to_h { |k| [project_key(k), true] }
    when String, Integer, Float, TrueClass, FalseClass, NilClass
      obj
    else
      # Anything else is a Ruby object the suite cannot have meant. Naming the
      # class makes the report say what happened instead of silently coercing.
      "#<#{obj.class}>"
    end
  end

  # JSON object keys are strings, so a non-string key has to be rendered.
  # Psych producing a non-string key is itself often the finding.
  def self.project_key(key)
    k = project(key)
    k.is_a?(String) ? k : JSON.generate(k)
  end

  # Documents are compared one per stream position. safe_load is deliberately
  # not used: this measures what Psych's parser and scalar scanner do, and a
  # permitted-classes refusal would score a safety policy as a parse failure.
  def self.stream(yaml)
    Psych.parse_stream(yaml).children.map do |doc|
      s = Psych::Nodes::Stream.new
      s.children << doc
      project(s.to_ruby.first)
    end
  end
end

# --- the batch protocol ------------------------------------------------------

MODE_JSON = ARGV.include?('--json')

$stdin.binmode
$stdout.binmode

loop do
  id = $stdin.gets
  break if id.nil?

  id = id.chomp
  break if id == '.'

  len = Integer($stdin.gets.chomp)
  doc = $stdin.read(len)

  begin
    text = doc.force_encoding(Encoding::UTF_8)
    lines = if MODE_JSON
              [JSON.generate(Value.stream(text))]
            else
              Emit.events(text)
            end
    $stdout.write("=== #{id} OK\n")
    lines.each { |l| $stdout.write("#{l}\n") }
  rescue Exception => e # rubocop:disable Lint/RescueException
    # Deliberately Exception: a parser that dies on a malformed document is
    # reporting a verdict, and a NoMemoryError or SystemStackError from a
    # pathological input is as much a result as a SyntaxError.
    msg = e.message.to_s.lines.first.to_s.strip
    $stdout.write("=== #{id} ERR\n#{e.class}: #{msg}\n")
  end
end
