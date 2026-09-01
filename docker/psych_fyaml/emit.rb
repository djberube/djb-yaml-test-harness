# frozen_string_literal: true

# Emits the yaml-test-suite event DSL for each document on stdin.
#
# Psych exposes the parse tree rather than the event stream, so the events are
# reconstructed by walking Psych::Nodes. That walk is faithful for everything
# the suite compares -- structure, anchors, tags, and scalar style -- because
# each node carries the properties its originating event did.
#
# Shared by the libyaml and libfyaml images; only the linked C parser differs.

require 'yaml'

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

# --- the batch protocol ------------------------------------------------------

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
    lines = Emit.events(doc.force_encoding(Encoding::UTF_8))
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
