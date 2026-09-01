package yaml

// yaml.v3 carries a complete libyaml-style event struct internally -- the
// parser in parserc.go already resolves %TAG handles, percent-decodes tag
// suffixes and tracks whether each tag and document marker was implicit -- but
// none of it is exported. The public surface is yaml.Node, and that tree drops
// exactly the three things the suite's event DSL compares: the explicit ---/...
// markers, whether a tag was written or inferred (a plain `a` arrives tagged
// !!str either way), and the non-specific `!`.
//
// So this file is added alongside the upstream sources rather than wrapping
// them: it is the smallest shim that re-exports the events the parser already
// produces. Everything else in this directory is unmodified yaml.v3 v3.0.1.

import "fmt"

type EventType int

const (
	EventNone EventType = iota
	EventStreamStart
	EventStreamEnd
	EventDocumentStart
	EventDocumentEnd
	EventAlias
	EventScalar
	EventSequenceStart
	EventSequenceEnd
	EventMappingStart
	EventMappingEnd
)

type ScalarStyle int

const (
	StyleAny ScalarStyle = iota
	StylePlain
	StyleSingleQuoted
	StyleDoubleQuoted
	StyleLiteral
	StyleFolded
)

// Event is the subset of yaml_event_t the event DSL needs.
type Event struct {
	Type   EventType
	Anchor string
	Tag    string
	Value  string

	// Implicit means the document marker was absent, or -- for a node -- that
	// no tag was written and the parser inferred one. QuotedImplicit is the
	// same question for a non-plain scalar, which is how the non-specific `!`
	// is told apart from a genuinely untagged quoted scalar.
	Implicit       bool
	QuotedImplicit bool

	ScalarStyle ScalarStyle
	Flow        bool
}

// Parser yields the parser's own events for a stream.
type Parser struct {
	parser yaml_parser_t
	done   bool
}

func NewParser(input []byte) *Parser {
	p := &Parser{}
	if !yaml_parser_initialize(&p.parser) {
		panic("failed to initialize YAML parser")
	}
	yaml_parser_set_input_string(&p.parser, input)
	return p
}

func (p *Parser) Destroy() {
	yaml_parser_delete(&p.parser)
}

// Next returns the next event, or an error. It reports io-style completion by
// returning an EventStreamEnd event; callers stop there.
func (p *Parser) Next() (Event, error) {
	var ev yaml_event_t
	if !yaml_parser_parse(&p.parser, &ev) {
		return Event{}, p.error()
	}
	defer yaml_event_delete(&ev)

	out := Event{
		Anchor:         string(ev.anchor),
		Tag:            string(ev.tag),
		Value:          string(ev.value),
		Implicit:       ev.implicit,
		QuotedImplicit: ev.quoted_implicit,
	}

	switch ev.typ {
	case yaml_STREAM_START_EVENT:
		out.Type = EventStreamStart
	case yaml_STREAM_END_EVENT:
		out.Type = EventStreamEnd
	case yaml_DOCUMENT_START_EVENT:
		out.Type = EventDocumentStart
		// yaml_parser_parse_document_start builds the implicit-document event
		// from a struct literal that never assigns `implicit`, so the flag
		// reads false for both kinds and only the explicit branch is telling
		// the truth. The branches are still distinguishable by the state they
		// leave behind: an explicit document routes through DOCUMENT_CONTENT,
		// an implicit one goes straight to BLOCK_NODE.
		out.Implicit = p.parser.state == yaml_PARSE_BLOCK_NODE_STATE
	case yaml_DOCUMENT_END_EVENT:
		out.Type = EventDocumentEnd
	case yaml_ALIAS_EVENT:
		out.Type = EventAlias
	case yaml_SCALAR_EVENT:
		out.Type = EventScalar
		switch ev.scalar_style() {
		case yaml_PLAIN_SCALAR_STYLE:
			out.ScalarStyle = StylePlain
		case yaml_SINGLE_QUOTED_SCALAR_STYLE:
			out.ScalarStyle = StyleSingleQuoted
		case yaml_DOUBLE_QUOTED_SCALAR_STYLE:
			out.ScalarStyle = StyleDoubleQuoted
		case yaml_LITERAL_SCALAR_STYLE:
			out.ScalarStyle = StyleLiteral
		case yaml_FOLDED_SCALAR_STYLE:
			out.ScalarStyle = StyleFolded
		}
	case yaml_SEQUENCE_START_EVENT:
		out.Type = EventSequenceStart
		out.Flow = ev.sequence_style() == yaml_sequence_style_t(yaml_FLOW_SEQUENCE_STYLE)
	case yaml_SEQUENCE_END_EVENT:
		out.Type = EventSequenceEnd
	case yaml_MAPPING_START_EVENT:
		out.Type = EventMappingStart
		out.Flow = ev.mapping_style() == yaml_mapping_style_t(yaml_FLOW_MAPPING_STYLE)
	case yaml_MAPPING_END_EVENT:
		out.Type = EventMappingEnd
	case yaml_TAIL_COMMENT_EVENT:
		// Comment bookkeeping, not a structural event; skip it.
		return p.Next()
	default:
		return Event{}, fmt.Errorf("unhandled event type %d", ev.typ)
	}
	return out, nil
}

// error turns the parser's own failure state into a Go error, preserving the
// distinction libyaml draws between a scanner and a parser problem.
func (p *Parser) error() error {
	switch p.parser.error {
	case yaml_SCANNER_ERROR:
		if p.parser.context != "" {
			return &ParseError{Kind: "ScannerError", Message: fmt.Sprintf("%s %s at line %d, column %d",
				p.parser.context, p.parser.problem, p.parser.problem_mark.line+1, p.parser.problem_mark.column+1)}
		}
		return &ParseError{Kind: "ScannerError", Message: fmt.Sprintf("%s at line %d, column %d",
			p.parser.problem, p.parser.problem_mark.line+1, p.parser.problem_mark.column+1)}
	case yaml_PARSER_ERROR:
		if p.parser.context != "" {
			return &ParseError{Kind: "ParserError", Message: fmt.Sprintf("%s %s at line %d, column %d",
				p.parser.context, p.parser.problem, p.parser.problem_mark.line+1, p.parser.problem_mark.column+1)}
		}
		return &ParseError{Kind: "ParserError", Message: fmt.Sprintf("%s at line %d, column %d",
			p.parser.problem, p.parser.problem_mark.line+1, p.parser.problem_mark.column+1)}
	case yaml_READER_ERROR:
		return &ParseError{Kind: "ReaderError", Message: p.parser.problem}
	}
	if p.parser.problem != "" {
		return &ParseError{Kind: "ParserError", Message: p.parser.problem}
	}
	return &ParseError{Kind: "ParserError", Message: "unknown parser failure"}
}

type ParseError struct {
	Kind    string
	Message string
}

func (e *ParseError) Error() string { return e.Message }
