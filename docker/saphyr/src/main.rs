// Emits the yaml-test-suite event DSL for each document on stdin.
//
// saphyr-parser exposes a genuine event stream, so this is a direct
// translation rather than a tree walk. Two things the DSL needs are not on the
// events, though, and both are recovered from the source text:
//
//   - Anchors arrive as numeric ids, because the parser's name->id map is
//     private. Ids are handed out sequentially from 1 as the parser meets each
//     anchor token, so scanning the source for anchor tokens in the same order
//     rebuilds the id->name mapping. See `anchor_names`.
//   - Collections carry no flow/block flag. A flow collection's start event
//     points at its opening `[` or `{`, and a block one points at its first
//     item, so the byte under the span start settles it.
//
// With --json, emits the loaded value as JSON instead of the event stream:
// what saphyr resolved the document to rather than what its parser built. The
// value comes from the `saphyr` crate's own loader, not a schema reimplemented
// here, so the numbers describe the library. saphyr targets YAML 1.2, so `yes`
// and `20:03:20` stay strings where the 1.1 parsers convert them.

use std::io::{self, Read, Write};

use saphyr::{LoadableYamlNode, Scalar, Yaml};
use saphyr_parser::{Event, Parser, ScalarStyle};

const VERSION: &str = "saphyr-parser 0.0.6";

fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            // Backslash first, so the escapes introduced below are not
            // escaped a second time.
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\u{b}' => out.push_str("\\v"),
            '\0' => out.push_str("\\0"),
            '\u{7}' => out.push_str("\\a"),
            '\u{1b}' => out.push_str("\\e"),
            _ => out.push(c),
        }
    }
    out
}

fn style_char(style: ScalarStyle) -> char {
    match style {
        ScalarStyle::Plain => ':',
        ScalarStyle::SingleQuoted => '\'',
        ScalarStyle::DoubleQuoted => '"',
        ScalarStyle::Literal => '|',
        ScalarStyle::Folded => '>',
    }
}

/// Anchor names in the order the parser registers them, so index N-1 holds the
/// name for anchor id N.
///
/// This walks the source rather than the token stream, so it has to skip the
/// places an `&` is content instead of an anchor: inside quoted scalars, after
/// a `#` comment, and inside block scalars. Getting one of those wrong shifts
/// every later name, so the skipping is deliberately conservative.
fn anchor_names(src: &str) -> Vec<String> {
    let b = src.as_bytes();
    let mut names = Vec::new();
    let mut i = 0usize;
    // Column tracking is needed to recognise a block scalar's indented body
    // and to know when a `#` really starts a comment.
    let mut at_line_start = true;

    while i < b.len() {
        match b[i] {
            b'\n' => {
                at_line_start = true;
                i += 1;
                continue;
            }
            b'\'' => {
                // Single-quoted: '' is an escaped quote.
                i += 1;
                while i < b.len() {
                    if b[i] == b'\'' {
                        if i + 1 < b.len() && b[i + 1] == b'\'' {
                            i += 2;
                            continue;
                        }
                        i += 1;
                        break;
                    }
                    i += 1;
                }
                at_line_start = false;
                continue;
            }
            b'"' => {
                i += 1;
                while i < b.len() {
                    if b[i] == b'\\' {
                        i += 2;
                        continue;
                    }
                    if b[i] == b'"' {
                        i += 1;
                        break;
                    }
                    i += 1;
                }
                at_line_start = false;
                continue;
            }
            b'#' => {
                // A `#` opens a comment only at the start of a line or after
                // whitespace; elsewhere it is ordinary scalar content.
                if at_line_start || (i > 0 && (b[i - 1] == b' ' || b[i - 1] == b'\t')) {
                    while i < b.len() && b[i] != b'\n' {
                        i += 1;
                    }
                    continue;
                }
                i += 1;
                at_line_start = false;
                continue;
            }
            b'|' | b'>' => {
                // A block scalar header runs to end of line; its body is every
                // following line indented past the header's own line. `&` in
                // that body is content, so the whole body is skipped.
                let line_indent = line_indent_of(b, i);
                let mut j = i;
                while j < b.len() && b[j] != b'\n' {
                    j += 1;
                }
                // Only a header if the rest of the line is a chomping/indent
                // indicator or a comment -- otherwise this is scalar content.
                let rest = &src[i + 1..j];
                let header = rest.chars().all(|c| {
                    c.is_ascii_digit() || c == '+' || c == '-' || c == ' ' || c == '\t'
                }) || rest.trim_start().starts_with('#');
                if !header {
                    i += 1;
                    at_line_start = false;
                    continue;
                }
                i = j;
                // Consume the indented body.
                while i < b.len() {
                    let line_start = i + 1;
                    if line_start >= b.len() {
                        break;
                    }
                    let mut k = line_start;
                    while k < b.len() && (b[k] == b' ') {
                        k += 1;
                    }
                    let indent = k - line_start;
                    let blank = k >= b.len() || b[k] == b'\n';
                    if !blank && indent <= line_indent {
                        break;
                    }
                    i = line_start;
                    while i < b.len() && b[i] != b'\n' {
                        i += 1;
                    }
                }
                at_line_start = true;
                continue;
            }
            b'&' => {
                let start = i + 1;
                let mut j = start;
                while j < b.len() && is_anchor_char(b[j]) {
                    j += 1;
                }
                if j > start {
                    names.push(src[start..j].to_string());
                }
                i = j;
                at_line_start = false;
                continue;
            }
            b' ' | b'\t' => {
                i += 1;
                continue;
            }
            _ => {
                i += 1;
                at_line_start = false;
                continue;
            }
        }
    }
    names
}

// An anchor name runs to the first whitespace or flow indicator. The `:` is
// deliberately allowed: `&an:chor` is one anchor named "an:chor".
fn is_anchor_char(c: u8) -> bool {
    !matches!(
        c,
        b' ' | b'\t' | b'\n' | b'\r' | b',' | b'[' | b']' | b'{' | b'}'
    )
}

fn line_indent_of(b: &[u8], pos: usize) -> usize {
    let mut start = pos;
    while start > 0 && b[start - 1] != b'\n' {
        start -= 1;
    }
    let mut k = start;
    while k < b.len() && b[k] == b' ' {
        k += 1;
    }
    k - start
}

/// Whether a collection start event opens a flow collection.
///
/// A flow collection's start event spans its opening `[` or `{`, while a block
/// one has an empty span pointing at its first item. Requiring a non-empty
/// span matters when a block mapping's key is itself a flow collection
/// (`[flow]: block`): both events report the same index, and only the inner
/// one actually covers the bracket.
///
/// The remaining case is the implicit mapping a `k: v` pair forms inside a
/// flow sequence. It has no brace of its own, so the caller treats a
/// collection opening within its parent's brackets as flow too.
fn is_flow_at(src: &str, start: usize, end: usize) -> bool {
    end > start && matches!(src.as_bytes().get(start), Some(b'[') | Some(b'{'))
}

/// The index just past the bracket closing the flow collection that opens at
/// `idx`, skipping over quoted scalars so a bracket inside a string does not
/// count. Returns the end of input if the document never closes it.
fn flow_extent(src: &str, idx: usize) -> usize {
    let b = src.as_bytes();
    let mut depth = 0usize;
    let mut i = idx;
    while i < b.len() {
        match b[i] {
            b'[' | b'{' => depth += 1,
            b']' | b'}' => {
                depth -= 1;
                if depth == 0 {
                    return i + 1;
                }
            }
            b'\'' => {
                i += 1;
                while i < b.len() {
                    if b[i] == b'\'' {
                        if i + 1 < b.len() && b[i + 1] == b'\'' {
                            i += 2;
                            continue;
                        }
                        break;
                    }
                    i += 1;
                }
            }
            b'"' => {
                i += 1;
                while i < b.len() {
                    if b[i] == b'\\' {
                        i += 2;
                        continue;
                    }
                    if b[i] == b'"' {
                        break;
                    }
                    i += 1;
                }
            }
            _ => {}
        }
        i += 1;
    }
    b.len()
}

fn events(src: &str) -> Result<Vec<String>, String> {
    let names = anchor_names(src);
    let anchor_name = |id: usize| -> String {
        // A miss would mean the scan and the parser disagreed; falling back to
        // the id keeps the mismatch visible rather than silently dropping it.
        names
            .get(id.wrapping_sub(1))
            .cloned()
            .unwrap_or_else(|| id.to_string())
    };

    let mut out = Vec::new();
    // For each open collection, the byte at which its flow context ends: the
    // matching `]`/`}` for a flow collection, or None for a block one. A
    // `k: v` pair inside a flow sequence starts an implicit mapping with no
    // brace of its own, so it is flow by virtue of sitting inside its parent's
    // brackets rather than by its own span. The bound matters because the
    // reverse also happens -- a block mapping may have a flow collection as
    // its key, and its later entries are not flow.
    let mut flow_stack: Vec<Option<usize>> = Vec::new();
    let mut parser = Parser::new_from_str(src);
    // The suite reports `-DOC ...` only for a document closed by an explicit
    // `...`. DocumentEnd carries no flag, but its span covers the marker when
    // there is one.
    while let Some(next) = parser.next_event() {
        let (ev, span) = next.map_err(|e| e.to_string())?;
        let start = span.start.index();
        // Inherit flow only while genuinely inside the parent's brackets.
        let inherited_end = flow_stack.last().copied().flatten().unwrap_or(0);
        let in_flow = start < inherited_end;
        match ev {
            Event::StreamStart => out.push("+STR".to_string()),
            Event::StreamEnd => {
                out.push("-STR".to_string());
                break;
            }
            Event::DocumentStart(explicit) => {
                out.push(if explicit { "+DOC ---" } else { "+DOC" }.to_string());
            }
            Event::DocumentEnd => {
                let explicit = src.get(start..start + 3) == Some("...");
                out.push(if explicit { "-DOC ..." } else { "-DOC" }.to_string());
            }
            Event::MappingStart(anchor, tag) => {
                let own = is_flow_at(src, start, span.end.index());
                let flow = own || in_flow;
                flow_stack.push(flow.then(|| {
                    if own { flow_extent(src, start) } else { inherited_end }
                }));
                out.push(format!(
                    "+MAP{}{}",
                    if flow { " {}" } else { "" },
                    props(anchor, tag.as_deref(), &anchor_name)
                ));
            }
            Event::MappingEnd => {
                flow_stack.pop();
                out.push("-MAP".to_string());
            }
            Event::SequenceStart(anchor, tag) => {
                let own = is_flow_at(src, start, span.end.index());
                let flow = own || in_flow;
                flow_stack.push(flow.then(|| {
                    if own { flow_extent(src, start) } else { inherited_end }
                }));
                out.push(format!(
                    "+SEQ{}{}",
                    if flow { " []" } else { "" },
                    props(anchor, tag.as_deref(), &anchor_name)
                ));
            }
            Event::SequenceEnd => {
                flow_stack.pop();
                out.push("-SEQ".to_string());
            }
            Event::Scalar(value, style, anchor, tag) => {
                // saphyr materialises a missing value as the literal "~"
                // (Event::empty_scalar), a placeholder it invents rather than
                // text the document contained. The span of such an event is
                // empty or points at whatever token came next, so the test is
                // whether the source it covers really is a `~`: a document
                // that genuinely writes `~` spans exactly that byte.
                let value = if value == "~"
                    && style == ScalarStyle::Plain
                    && src.get(start..span.end.index()) != Some("~")
                {
                    ""
                } else {
                    &value
                };
                out.push(format!(
                    "=VAL{} {}{}",
                    props(anchor, tag.as_deref(), &anchor_name),
                    style_char(style),
                    escape(value)
                ));
            }
            Event::Alias(id) => out.push(format!("=ALI *{}", anchor_name(id))),
            Event::Nothing => {}
        }
    }
    Ok(out)
}

/// Anchor then tag, in the order and spacing the suite uses. The parser has
/// already applied %TAG directives and percent-decoded the suffix, so the
/// resolved tag is just handle followed by suffix.
fn props(
    anchor: usize,
    tag: Option<&saphyr_parser::Tag>,
    anchor_name: &dyn Fn(usize) -> String,
) -> String {
    let mut s = String::new();
    if anchor > 0 {
        s.push_str(&format!(" &{}", anchor_name(anchor)));
    }
    if let Some(t) = tag {
        s.push_str(&format!(" <{}{}>", t.handle, t.suffix));
    }
    s
}

// --- batch protocol ---------------------------------------------------------
//
// stdin:  (<id>\n<nbytes>\n<bytes>)* then "."
// stdout: ("=== <id> <OK|ERR>\n" <lines>)*

/// Writes a JSON string literal, escaping what JSON requires.
fn json_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

/// Projects a loaded value onto JSON's type set.
///
/// Lossy in one direction only: anything JSON cannot represent is rendered so
/// that it cannot accidentally equal a correct answer. An alias that saphyr
/// could not resolve, or a BadValue, has to stay visible as a difference.
fn project(node: &Yaml, out: &mut String) {
    match node {
        Yaml::Value(Scalar::Null) => out.push_str("null"),
        Yaml::Value(Scalar::Boolean(b)) => out.push_str(if *b { "true" } else { "false" }),
        Yaml::Value(Scalar::Integer(i)) => out.push_str(&i.to_string()),
        Yaml::Value(Scalar::FloatingPoint(f)) => {
            let v = f.into_inner();
            // JSON has no NaN or Infinity; tag them rather than emit invalid JSON.
            if v.is_nan() {
                json_string("#<NaN>", out);
            } else if v.is_infinite() {
                json_string(if v > 0.0 { "#<Infinity>" } else { "#<-Infinity>" }, out);
            } else {
                out.push_str(&v.to_string());
            }
        }
        Yaml::Value(Scalar::String(s)) => json_string(s, out),
        Yaml::Sequence(items) => {
            out.push('[');
            for (i, it) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                project(it, out);
            }
            out.push(']');
        }
        Yaml::Mapping(map) => {
            out.push('{');
            for (i, (k, v)) in map.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                // JSON object keys are strings; a non-string key is itself
                // often the finding, so it is rendered rather than dropped.
                match k {
                    Yaml::Value(Scalar::String(s)) => json_string(s, out),
                    other => {
                        let mut inner = String::new();
                        project(other, &mut inner);
                        json_string(&inner, out);
                    }
                }
                out.push(':');
                project(v, out);
            }
            out.push('}');
        }
        other => {
            json_string(&format!("#<{other:?}>"), out);
        }
    }
}

/// Every document in the stream, as one JSON array.
fn values(text: &str) -> Result<Vec<String>, String> {
    let docs = Yaml::load_from_str(text).map_err(|e| e.to_string())?;
    let mut out = String::from("[");
    for (i, d) in docs.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        project(d, &mut out);
    }
    out.push(']');
    Ok(vec![out])
}

fn main() {
    let json_mode = std::env::args().skip(1).any(|a| a == "--json");
    if std::env::args().skip(1).any(|a| a == "--version") {
        println!("{VERSION}");
        return;
    }

    let mut buf = Vec::new();
    io::stdin().read_to_end(&mut buf).expect("read stdin");
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());

    let mut pos = 0usize;
    let read_line = |buf: &[u8], pos: &mut usize| -> Option<String> {
        let nl = buf[*pos..].iter().position(|&c| c == b'\n')?;
        let s = String::from_utf8_lossy(&buf[*pos..*pos + nl]).into_owned();
        *pos += nl + 1;
        Some(s)
    };

    loop {
        if pos >= buf.len() {
            break;
        }
        let Some(id) = read_line(&buf, &mut pos) else {
            break;
        };
        let id = id.trim().to_string();
        if id == "." {
            break;
        }
        let Some(nline) = read_line(&buf, &mut pos) else {
            break;
        };
        let Ok(n) = nline.trim().parse::<usize>() else {
            break;
        };
        if pos + n > buf.len() {
            break;
        }
        let doc = &buf[pos..pos + n];
        pos += n;

        // A document that is not valid UTF-8 is the parser's verdict to give,
        // but saphyr only accepts &str, so it is reported here instead.
        let text = match std::str::from_utf8(doc) {
            Ok(t) => t,
            Err(e) => {
                writeln!(out, "=== {id} ERR").unwrap();
                writeln!(out, "Utf8Error: {e}").unwrap();
                continue;
            }
        };

        // A parser that overflows the stack on a pathological document is
        // still reporting a verdict, so a panic is caught and recorded rather
        // than taking down the batch.
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            if json_mode {
                values(text)
            } else {
                events(text)
            }
        }));

        match result {
            Ok(Ok(lines)) => {
                writeln!(out, "=== {id} OK").unwrap();
                for l in lines {
                    writeln!(out, "{l}").unwrap();
                }
            }
            Ok(Err(msg)) => {
                let first = msg.lines().next().unwrap_or("").trim().to_string();
                writeln!(out, "=== {id} ERR").unwrap();
                writeln!(out, "ScanError: {first}").unwrap();
            }
            Err(_) => {
                writeln!(out, "=== {id} ERR").unwrap();
                writeln!(out, "PanicError: parser panicked").unwrap();
            }
        }
    }
    out.flush().unwrap();
}
