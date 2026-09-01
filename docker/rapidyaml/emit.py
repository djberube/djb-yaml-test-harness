"""Emits the yaml-test-suite event DSL for each document on stdin, via rapidyaml.

rapidyaml exposes a tree rather than an event stream, so the events are
reconstructed by walking it. The tree keeps enough of the source to recover
most of what the suite compares -- structure, anchors, aliases and scalar
style -- but ryml folds a stream into a single tree, so multi-document
streams are walked document by document from the root's children.

Two things the suite reports are absent from the tree entirely: the explicit
`---` / `...` document markers, and the `%TAG` prefixes that give shorthand
tags their meaning. Both are recovered by a lexical prescan of the source,
below.
"""

import os
import re
import sys

import ryml


def escape(s):
    out = s.replace("\\", "\\\\")
    for ch, rep in (
        ("\n", "\\n"), ("\t", "\\t"), ("\r", "\\r"), ("\b", "\\b"),
        ("\f", "\\f"), ("\v", "\\v"), ("\0", "\\0"), ("\a", "\\a"),
        ("\x1b", "\\e"),
    ):
        out = out.replace(ch, rep)
    return out


def text(raw):
    if raw is None:
        return ""
    return bytes(raw).decode("utf-8", "replace")


# ---------------------------------------------------------------- tags

PERCENT = re.compile(r"%([0-9A-Fa-f]{2})")

DEFAULT_TAGS = {"!!": "tag:yaml.org,2002:"}


def unescape_tag(suffix):
    """Percent escapes in a tag suffix denote literal bytes, so decode them."""
    raw = PERCENT.sub(lambda m: chr(int(m.group(1), 16)), suffix)
    return raw


def resolve_tag(raw, prefixes):
    """Expand a tag as written in the source into the fully resolved form.

    ryml hands back the source spelling, with verbatim tags already stripped
    to `<...>`. Shorthands resolve against the document's `%TAG` prefixes,
    falling back to the two YAML defaults; a bare `!` is its own tag and a
    primary shorthand keeps its `!` when no `%TAG !` overrides it.
    """
    if raw.startswith("<") and raw.endswith(">"):
        return unescape_tag(raw[1:-1])
    if raw == "!":
        return "!"
    if raw.startswith("!!"):
        prefix = prefixes.get("!!", DEFAULT_TAGS["!!"])
        return unescape_tag(prefix + raw[2:])
    if raw.startswith("!"):
        # A named handle looks like !handle!suffix; anything else is the
        # primary handle applied to the rest of the token.
        end = raw.find("!", 1)
        if end != -1:
            handle = raw[:end + 1]
            if handle in prefixes:
                return unescape_tag(prefixes[handle] + raw[end + 1:])
        if "!" in prefixes:
            return unescape_tag(prefixes["!"] + raw[1:])
        return unescape_tag(raw)
    return unescape_tag(raw)


# ------------------------------------------------------- scalar styles

def val_style(tree, node):
    if tree.is_val_squo(node):
        return "'"
    if tree.is_val_dquo(node):
        return '"'
    if tree.is_val_literal(node):
        return "|"
    if tree.is_val_folded(node):
        return ">"
    return ":"


def key_style(tree, node):
    if tree.is_key_squo(node):
        return "'"
    if tree.is_key_dquo(node):
        return '"'
    if tree.is_key_literal(node):
        return "|"
    if tree.is_key_folded(node):
        return ">"
    return ":"


# ------------------------------------------------------------- walking

def props(tree, node, prefixes):
    out = ""
    if tree.has_val_anchor(node):
        out += " &" + text(tree.val_anchor(node))
    if tree.has_val_tag(node):
        out += " <" + resolve_tag(text(tree.val_tag(node)), prefixes) + ">"
    return out


def walk(tree, node, out, prefixes):
    if tree.is_map(node):
        style = " {}" if tree.is_flow_sl(node) or tree.is_flow_ml(node) else ""
        out.append("+MAP" + style + props(tree, node, prefixes))
        for child in ryml.children(tree, node):
            emit_key(tree, child, out, prefixes)
            walk(tree, child, out, prefixes)
        out.append("-MAP")
    elif tree.is_seq(node):
        style = " []" if tree.is_flow_sl(node) or tree.is_flow_ml(node) else ""
        out.append("+SEQ" + style + props(tree, node, prefixes))
        for child in ryml.children(tree, node):
            walk(tree, child, out, prefixes)
        out.append("-SEQ")
    elif tree.is_val_ref(node):
        out.append("=ALI *" + text(tree.val_ref(node)))
    else:
        out.append("=VAL" + props(tree, node, prefixes) + " "
                   + val_style(tree, node) + escape(text(tree.val(node))))


def emit_key(tree, node, out, prefixes):
    """A mapping child carries its own key, which the suite reports as a scalar."""
    if not tree.has_key(node):
        return
    if tree.is_key_ref(node):
        out.append("=ALI *" + text(tree.key_ref(node)))
        return
    pre = ""
    if tree.has_key_anchor(node):
        pre += " &" + text(tree.key_anchor(node))
    if tree.has_key_tag(node):
        pre += " <" + resolve_tag(text(tree.key_tag(node)), prefixes) + ">"
    out.append("=VAL" + pre + " " + key_style(tree, node)
               + escape(text(tree.key(node))))


# ------------------------------------------------- source-level prescan

# A block scalar header is an optional indentation digit and chomping
# indicator in either order, then nothing but a comment.
BLOCK_HEADER = re.compile(r"^([0-9]*)([+-]?)([0-9]*)[ \t]*(#.*)?$")

TAG_DIRECTIVE = re.compile(r"^%TAG\s+(\S+)\s+(\S+)\s*$")


def scan_line(line, flow):
    """Track flow depth across one line and report a block scalar it opens.

    This is deliberately shallow: it exists only so the document-marker scan
    can tell a real `---` from those three characters appearing inside a
    scalar or a flow collection.
    """
    block_indent = None
    block_pending = False
    j = 0
    n = len(line)
    while j < n:
        ch = line[j]
        if ch == "#" and (j == 0 or line[j - 1] in " \t"):
            break
        if ch == "'":
            j += 1
            while j < n:
                if line[j] == "'":
                    if j + 1 < n and line[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
        elif ch == '"':
            j += 1
            while j < n:
                if line[j] == "\\":
                    j += 2
                    continue
                if line[j] == '"':
                    break
                j += 1
        elif ch in "[{":
            flow += 1
        elif ch in "]}":
            flow = max(0, flow - 1)
        elif ch in "|>" and flow == 0:
            m = BLOCK_HEADER.match(line[j + 1:])
            if m:
                base = len(line) - len(line.lstrip(" "))
                digits = m.group(1) or m.group(3)
                if digits:
                    block_indent = base + int(digits)
                else:
                    # Without an explicit indicator the block takes its
                    # indentation from its first non-empty line.
                    block_pending = True
                return flow, block_indent, block_pending
        j += 1
    return flow, block_indent, block_pending


def is_marker(line, flow):
    """True when the line is a `---` or `...` acting as a document boundary."""
    if flow:
        return None
    head = line[:3]
    if head not in ("---", "..."):
        return None
    if len(line) > 3 and line[3] not in " \t":
        return None
    return head


def segments(src):
    """Split the source into documents, recording each one's markers.

    Returns a list of dicts with `start` (an explicit `---` opened it), `end`
    (an explicit `...` closed it) and the `%TAG` prefixes in force. A document
    exists where there is content, or where a `---` asserts an empty one; a
    stream of nothing but comments and `...` has no documents at all, which is
    what the suite expects.
    """
    lines = src.split("\n")
    out = []
    flow = 0
    block_indent = None
    block_pending = False
    prefixes = {}
    cur = {"start": False, "end": False, "content": False, "tags": dict(prefixes)}

    def flush():
        if cur["content"] or cur["start"]:
            out.append(dict(cur))
        cur.update({"start": False, "end": False, "content": False,
                    "tags": dict(prefixes)})

    i = 0
    while i < len(lines):
        line = lines[i]

        if block_pending or block_indent is not None:
            if line.strip() == "":
                i += 1
                continue
            indent = len(line) - len(line.lstrip(" "))
            if block_pending:
                block_pending = False
                if indent > 0:
                    block_indent = indent
                    i += 1
                    continue
                block_indent = None
            elif indent >= block_indent:
                i += 1
                continue
            else:
                block_indent = None

        mark = is_marker(line, flow)
        if mark == "---":
            flush()
            cur["start"] = True
            cur["tags"] = dict(prefixes)
            rest = line[3:]
            if rest.strip() and not rest.lstrip().startswith("#"):
                cur["content"] = True
            flow, block_indent, block_pending = scan_line(rest, flow)
            i += 1
            continue
        if mark == "...":
            cur["end"] = True
            flush()
            # Directives do not survive a document end.
            prefixes = {}
            cur["tags"] = {}
            i += 1
            continue

        stripped = line.strip()
        directive = TAG_DIRECTIVE.match(stripped)
        if directive:
            prefixes[directive.group(1)] = unescape_tag(directive.group(2))
            cur["tags"] = dict(prefixes)
        elif stripped and not stripped.startswith("#") and not stripped.startswith("%"):
            cur["content"] = True

        flow, block_indent, block_pending = scan_line(line, flow)
        i += 1

    flush()
    return out


# ------------------------------------------------------------- emission

def events(src):
    tree = ryml.parse_in_arena(src.encode("utf-8"))
    root = tree.root_id()

    if tree.is_stream(root):
        docs = list(ryml.children(tree, root))
    elif tree.is_container(root) or tree.has_val(root) or tree.is_val(root):
        docs = [root]
    else:
        # A bare NOTYPE root means the source held nothing but comments,
        # blank lines or a stray `...`, which is a stream of no documents.
        docs = []

    segs = segments(src)
    # The prescan and the tree should agree on the document count; where they
    # do not, trust the tree for structure and fall back to unmarked
    # documents rather than mispairing the markers.
    if len(segs) != len(docs):
        segs = [{"start": False, "end": False, "tags": {}} for _ in docs]

    out = ["+STR"]
    for node, seg in zip(docs, segs):
        out.append("+DOC ---" if seg["start"] else "+DOC")
        walk(tree, node, out, seg["tags"])
        out.append("-DOC ..." if seg["end"] else "-DOC")
    out.append("-STR")
    return out


def parse_quietly(src):
    """ryml's error handler writes to fd 2 before raising, so mute the fd.

    The message survives on the exception, which is all the batch protocol
    needs; letting it through would interleave the C++ diagnostic with the
    event stream of whichever case is being emitted.
    """
    devnull = os.open(os.devnull, os.O_WRONLY)
    saved = os.dup(2)
    try:
        os.dup2(devnull, 2)
        return events(src)
    finally:
        os.dup2(saved, 2)
        os.close(saved)
        os.close(devnull)


def main():
    stdin = sys.stdin.buffer
    while True:
        line = stdin.readline()
        if not line:
            break
        case_id = line.decode("utf-8").strip()
        if case_id == ".":
            break
        nbytes = int(stdin.readline().decode("utf-8").strip())
        doc = stdin.read(nbytes)
        try:
            lines = parse_quietly(doc.decode("utf-8"))
            sys.stdout.write("=== %s OK\n" % case_id)
            sys.stdout.write("".join(l + "\n" for l in lines))
        except BaseException as exc:
            msg = (getattr(exc, "msg", "") or str(exc)).strip().splitlines()
            msg = msg[0] if msg else "parse error"
            sys.stdout.write("=== %s ERR\n%s: %s\n" % (case_id, type(exc).__name__, msg))
        sys.stdout.flush()


if __name__ == "__main__":
    main()
