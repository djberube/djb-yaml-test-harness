"""Emits the yaml-test-suite event DSL for each document on stdin.

PyYAML exposes parser events directly, so unlike the Ruby emitter this is a
straight translation rather than a tree walk.

Runs both PyYAML backends: the pure-Python parser by default, and the libyaml
binding with --c. Same image, same code -- the only difference is which Loader
class supplies the events, which is exactly the comparison worth making.

With --json, emits the *loaded value* as JSON instead of the event stream.
That is a different question about the same parser: the events are what the
parser built, the JSON is what PyYAML's constructor resolved them to. PyYAML
implements the YAML 1.1 type set, so `yes` becomes True and `20:03:20` becomes
72200 -- neither of which the event stream shows.
"""

import datetime
import json
import sys

import yaml

C_MODE = "--c" in sys.argv[1:]
JSON_MODE = "--json" in sys.argv[1:]

# Check the flag PyYAML sets when its extension loaded, not for a particular
# class name: which of CParser/CSafeLoader/CLoader gets re-exported varies
# between builds, but __with_libyaml__ is the flag PyYAML itself consults.
if C_MODE and not yaml.__with_libyaml__:  # pragma: no cover
    sys.exit("libyaml bindings not available in this image")


def escape(s):
    out = s.replace("\\", "\\\\")
    for ch, rep in (
        ("\n", "\\n"), ("\t", "\\t"), ("\r", "\\r"), ("\b", "\\b"),
        ("\f", "\\f"), ("\v", "\\v"), ("\0", "\\0"), ("\a", "\\a"),
        ("\x1b", "\\e"),
    ):
        out = out.replace(ch, rep)
    return out


STYLE = {"'": "'", '"': '"', "|": "|", ">": ">", None: ":", "": ":"}


def props(ev):
    """Anchor and tag, in the order and spacing the suite uses."""
    out = ""
    anchor = getattr(ev, "anchor", None)
    if anchor:
        out += " &" + anchor
    tag = getattr(ev, "tag", None)
    if tag:
        out += " <" + tag + ">"
    return out


def events(text):
    """The suite's event lines for one document stream."""
    loader = yaml.CSafeLoader if C_MODE else yaml.SafeLoader
    out = []
    for ev in yaml.parse(text, Loader=loader):
        name = type(ev).__name__
        if name == "StreamStartEvent":
            out.append("+STR")
        elif name == "StreamEndEvent":
            out.append("-STR")
        elif name == "DocumentStartEvent":
            out.append("+DOC" if ev.explicit is False else "+DOC ---")
        elif name == "DocumentEndEvent":
            out.append("-DOC ..." if ev.explicit else "-DOC")
        elif name == "MappingStartEvent":
            style = " {}" if ev.flow_style else ""
            out.append("+MAP" + style + props(ev))
        elif name == "MappingEndEvent":
            out.append("-MAP")
        elif name == "SequenceStartEvent":
            style = " []" if ev.flow_style else ""
            out.append("+SEQ" + style + props(ev))
        elif name == "SequenceEndEvent":
            out.append("-SEQ")
        elif name == "ScalarEvent":
            # PyYAML reports a resolved tag on every scalar; the suite only
            # records one the document actually stated. implicit[0] says the
            # tag was inferred rather than written, so an inferred tag is
            # dropped -- except the non-specific `!`, which PyYAML reports as
            # tag "!" with implicit (True, False) even though it is written
            # in the document.
            tag = ""
            if ev.tag == "!":
                tag = " <!>"
            elif ev.tag and not (ev.implicit and ev.implicit[0]):
                tag = " <" + ev.tag + ">"
            anchor = " &" + ev.anchor if ev.anchor else ""
            out.append(
                "=VAL" + anchor + tag + " " + STYLE.get(ev.style, ":") + escape(ev.value)
            )
        elif name == "AliasEvent":
            out.append("=ALI *" + ev.anchor)
        else:  # pragma: no cover
            raise RuntimeError("unhandled event " + name)
    return out


def project(obj):
    """Project a loaded Python value onto JSON's type set.

    Lossy in one direction only: anything JSON cannot represent is rendered so
    that it cannot accidentally equal a correct answer. A date resolved where
    the suite expects a string has to stay visible as a difference.
    """
    if isinstance(obj, dict):
        return {project_key(k): project(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [project(v) for v in obj]
    if isinstance(obj, bool) or obj is None:
        return obj
    if isinstance(obj, (int, float, str)):
        return obj
    if isinstance(obj, (datetime.datetime, datetime.date)):
        return obj.isoformat()
    if isinstance(obj, bytes):
        # !!binary. The suite states these as strings, so decoding keeps a
        # correct answer comparable; an undecodable payload is tagged instead.
        try:
            return obj.decode("utf-8")
        except UnicodeDecodeError:
            return "#<bytes %d>" % len(obj)
    if isinstance(obj, set):
        return {project_key(k): True for k in obj}
    return "#<%s>" % type(obj).__name__


def project_key(key):
    """JSON object keys are strings. A non-string key is itself often the
    finding, so it is rendered rather than coerced away."""
    k = project(key)
    if isinstance(k, str):
        return k
    return json.dumps(k, sort_keys=True)


def values(text):
    loader = yaml.CSafeLoader if C_MODE else yaml.SafeLoader
    return [project(d) for d in yaml.load_all(text, Loader=loader)]


def main():
    stdin = sys.stdin.buffer
    stdout = sys.stdout

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
            if JSON_MODE:
                lines = [json.dumps(values(doc.decode("utf-8")))]
            else:
                lines = events(doc.decode("utf-8"))
            stdout.write("=== %s OK\n" % case_id)
            stdout.write("".join(l + "\n" for l in lines))
        except BaseException as exc:
            # BaseException on purpose: a RecursionError from a deeply nested
            # document is a parser verdict, not a harness failure.
            msg = str(exc).strip().splitlines()
            msg = msg[0] if msg else ""
            stdout.write("=== %s ERR\n%s: %s\n" % (case_id, type(exc).__name__, msg))
        stdout.flush()


if __name__ == "__main__":
    main()
