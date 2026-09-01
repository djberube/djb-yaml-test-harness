// Emits the yaml-test-suite event DSL for each document on stdin.
//
// gopkg.in/yaml.v3 exports only yaml.Node, a tree that has already discarded
// the explicit ---/... markers and the difference between a written and an
// inferred tag. Its internal parser does produce a full libyaml-style event
// stream, so the package is vendored under internal/goyaml with a small shim
// re-exporting those events; see internal/goyaml/events.go. This file is a
// direct translation of that stream, the same shape as the js-yaml emitter.
//
// With --json, emits the loaded value as JSON instead: what go-yaml resolved
// the document to rather than what its parser built. go-yaml decodes into
// interface{} using its own resolver, so `yes` becomes true and a timestamp
// becomes a time.Time -- neither of which the event stream shows.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	goyaml "github.com/djb/yaml-harness/go_yaml/internal/goyaml"
)

const version = "go-yaml.v3 v3.0.1"

var escaper = strings.NewReplacer(
	// Backslash first: the later replacements introduce backslashes of their
	// own, and a single pass over the original avoids escaping those again.
	"\\", "\\\\",
	"\n", "\\n",
	"\t", "\\t",
	"\r", "\\r",
	"\b", "\\b",
	"\f", "\\f",
	"\v", "\\v",
	"\x00", "\\0",
	"\a", "\\a",
	"\x1b", "\\e",
)

func escape(s string) string { return escaper.Replace(s) }

var styleChar = map[goyaml.ScalarStyle]string{
	goyaml.StylePlain:        ":",
	goyaml.StyleSingleQuoted: "'",
	goyaml.StyleDoubleQuoted: `"`,
	goyaml.StyleLiteral:      "|",
	goyaml.StyleFolded:       ">",
}

// Collection properties: the suite writes the style marker before the anchor
// and tag, so a flow sequence with an anchor is `+SEQ [] &a`.
func collectionProps(ev goyaml.Event) string {
	var b strings.Builder
	if ev.Anchor != "" {
		b.WriteString(" &" + ev.Anchor)
	}
	// The parser leaves Tag empty unless the document stated one, so unlike
	// the yaml.Node tree there is no inferred !!seq/!!map to filter out here.
	if ev.Tag != "" {
		b.WriteString(" <" + ev.Tag + ">")
	}
	return b.String()
}

func scalarLine(ev goyaml.Event) string {
	var b strings.Builder
	b.WriteString("=VAL")
	if ev.Anchor != "" {
		b.WriteString(" &" + ev.Anchor)
	}

	// The parser reports a tag on every scalar it resolves, but the suite
	// records only a tag the document actually wrote. Implicit says the tag
	// was inferred. The non-specific `!` is the exception: it is written in
	// the document yet arrives with Implicit set on a plain scalar, so it is
	// recognised by value rather than by the flag.
	if ev.Tag == "!" {
		b.WriteString(" <!>")
	} else if ev.Tag != "" && !ev.Implicit {
		b.WriteString(" <" + ev.Tag + ">")
	}

	style, ok := styleChar[ev.ScalarStyle]
	if !ok {
		style = ":"
	}
	b.WriteString(" " + style + escape(ev.Value))
	return b.String()
}

// events returns the suite's event lines for one document stream.
func events(src []byte) (lines []string, err error) {
	p := goyaml.NewParser(src)
	defer p.Destroy()

	// The vendored parser signals a few unrecoverable conditions -- a nesting
	// depth past its limit, most notably -- by panicking rather than by
	// returning an error. That is still the parser's verdict on the document,
	// so it is reported as one instead of taking down the batch.
	defer func() {
		if r := recover(); r != nil {
			lines = nil
			err = &goyaml.ParseError{Kind: "PanicError", Message: fmt.Sprint(r)}
		}
	}()

	for {
		ev, perr := p.Next()
		if perr != nil {
			return nil, perr
		}

		switch ev.Type {
		case goyaml.EventStreamStart:
			lines = append(lines, "+STR")
		case goyaml.EventStreamEnd:
			lines = append(lines, "-STR")
			return lines, nil
		case goyaml.EventDocumentStart:
			if ev.Implicit {
				lines = append(lines, "+DOC")
			} else {
				lines = append(lines, "+DOC ---")
			}
		case goyaml.EventDocumentEnd:
			if ev.Implicit {
				lines = append(lines, "-DOC")
			} else {
				lines = append(lines, "-DOC ...")
			}
		case goyaml.EventMappingStart:
			marker := ""
			if ev.Flow {
				marker = " {}"
			}
			lines = append(lines, "+MAP"+marker+collectionProps(ev))
		case goyaml.EventMappingEnd:
			lines = append(lines, "-MAP")
		case goyaml.EventSequenceStart:
			marker := ""
			if ev.Flow {
				marker = " []"
			}
			lines = append(lines, "+SEQ"+marker+collectionProps(ev))
		case goyaml.EventSequenceEnd:
			lines = append(lines, "-SEQ")
		case goyaml.EventScalar:
			lines = append(lines, scalarLine(ev))
		case goyaml.EventAlias:
			lines = append(lines, "=ALI *"+ev.Anchor)
		default:
			return nil, fmt.Errorf("unhandled event type %d", ev.Type)
		}
	}
}

// --- batch protocol ---------------------------------------------------------
//
// stdin:  (<id>\n<nbytes>\n<bytes>)* then "."
// stdout: ("=== <id> <OK|ERR>\n" <lines>)*

// project maps a decoded value onto JSON's type set. Lossy in one direction
// only: anything JSON cannot represent is rendered so it cannot accidentally
// equal a correct answer.
func project(v interface{}) interface{} {
	switch t := v.(type) {
	case nil:
		return nil
	case map[string]interface{}:
		out := make(map[string]interface{}, len(t))
		for k, val := range t {
			out[k] = project(val)
		}
		return out
	case map[interface{}]interface{}:
		out := make(map[string]interface{}, len(t))
		for k, val := range t {
			out[projectKey(k)] = project(val)
		}
		return out
	case []interface{}:
		out := make([]interface{}, len(t))
		for i, val := range t {
			out[i] = project(val)
		}
		return out
	case time.Time:
		return t.Format(time.RFC3339)
	case []byte:
		// !!binary. The suite states these as strings, so decoding keeps a
		// correct answer comparable.
		return string(t)
	case string, bool, int, int64, uint64, float64:
		return t
	default:
		return fmt.Sprintf("#<%T>", t)
	}
}

// JSON object keys are strings; a non-string key is itself often the finding,
// so it is rendered rather than coerced away.
func projectKey(k interface{}) string {
	p := project(k)
	if s, ok := p.(string); ok {
		return s
	}
	b, err := json.Marshal(p)
	if err != nil {
		return fmt.Sprintf("%v", p)
	}
	return string(b)
}

// values decodes every document in the stream, one JSON value each.
func values(doc []byte) ([]interface{}, error) {
	dec := goyaml.NewDecoder(strings.NewReader(string(doc)))
	out := []interface{}{}
	for {
		var v interface{}
		err := dec.Decode(&v)
		if err != nil {
			if err == io.EOF {
				return out, nil
			}
			return nil, err
		}
		out = append(out, project(v))
	}
}

func main() {
	jsonMode := false
	for _, a := range os.Args[1:] {
		if a == "--version" {
			fmt.Println(version)
			return
		}
		if a == "--json" {
			jsonMode = true
		}
	}

	in := bufio.NewReaderSize(os.Stdin, 1<<16)
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()

	for {
		idLine, err := in.ReadString('\n')
		if err != nil && idLine == "" {
			break
		}
		id := strings.TrimSpace(idLine)
		if id == "." {
			break
		}
		if id == "" && err != nil {
			break
		}

		nLine, err := in.ReadString('\n')
		if err != nil && nLine == "" {
			break
		}
		n, cerr := strconv.Atoi(strings.TrimSpace(nLine))
		if cerr != nil {
			break
		}

		doc := make([]byte, n)
		if _, err := io.ReadFull(in, doc); err != nil {
			break
		}

		var lines []string
		var eerr error
		if jsonMode {
			var vs []interface{}
			vs, eerr = values(doc)
			if eerr == nil {
				b, merr := json.Marshal(vs)
				if merr != nil {
					eerr = merr
				} else {
					lines = []string{string(b)}
				}
			}
		} else {
			lines, eerr = events(doc)
		}
		if eerr != nil {
			kind := "ParserError"
			if pe, ok := eerr.(*goyaml.ParseError); ok {
				kind = pe.Kind
			}
			msg := strings.TrimSpace(strings.SplitN(eerr.Error(), "\n", 2)[0])
			fmt.Fprintf(out, "=== %s ERR\n%s: %s\n", id, kind, msg)
			continue
		}

		fmt.Fprintf(out, "=== %s OK\n", id)
		for _, l := range lines {
			fmt.Fprintln(out, l)
		}
	}
}
