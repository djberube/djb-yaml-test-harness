// Emits the yaml-test-suite event DSL for each document on stdin.
//
// SnakeYAML Engine exposes a real event API through
// org.snakeyaml.engine.v2.api.lowlevel.Parse, so this is a direct translation
// like the PyYAML emitter rather than a tree walk.
//
// Two things the other emitters have to do by hand, the Engine already does:
// it resolves tag shorthands against the %TAG handles in scope (including
// percent-escapes in the suffix), and it reports an absent tag as an empty
// Optional rather than a resolved-by-inference one. So a written `!!str`
// arrives as tag:yaml.org,2002:str, a bare `!` arrives as "!", and an
// untagged plain scalar arrives with no tag at all -- which is exactly the
// suite's rule of recording only a tag the document actually stated.
//
// With --json, emits the loaded value as JSON instead of the event stream:
// what the Engine resolved the document to rather than what its parser built.
// SnakeYAML Engine implements the YAML 1.2 core schema, so `yes` stays a
// string where the 1.1 parsers make it a boolean.

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

import java.util.Map;
import java.util.Set;

import org.snakeyaml.engine.v2.api.Load;
import org.snakeyaml.engine.v2.api.LoadSettings;
import org.snakeyaml.engine.v2.api.lowlevel.Parse;
import org.snakeyaml.engine.v2.common.ScalarStyle;
import org.snakeyaml.engine.v2.events.AliasEvent;
import org.snakeyaml.engine.v2.events.CollectionStartEvent;
import org.snakeyaml.engine.v2.events.DocumentEndEvent;
import org.snakeyaml.engine.v2.events.DocumentStartEvent;
import org.snakeyaml.engine.v2.events.Event;
import org.snakeyaml.engine.v2.events.NodeEvent;
import org.snakeyaml.engine.v2.events.ScalarEvent;

public final class Emit {

  private static final String VERSION = "snakeyaml-engine2.9";

  private static String escape(String s) {
    StringBuilder out = new StringBuilder(s.length());
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      switch (c) {
        case '\\': out.append("\\\\"); break;
        case '\n': out.append("\\n"); break;
        case '\t': out.append("\\t"); break;
        case '\r': out.append("\\r"); break;
        case '\b': out.append("\\b"); break;
        case '\f': out.append("\\f"); break;
        case 0x0b: out.append("\\v"); break;
        case 0x00: out.append("\\0"); break;
        case 0x07: out.append("\\a"); break;
        case 0x1b: out.append("\\e"); break;
        default: out.append(c);
      }
    }
    return out.toString();
  }

  private static char styleChar(ScalarStyle style) {
    switch (style) {
      case SINGLE_QUOTED: return '\'';
      case DOUBLE_QUOTED: return '"';
      case LITERAL: return '|';
      case FOLDED: return '>';
      default: return ':';
    }
  }

  /** Anchor then tag, in the order and spacing the suite uses. */
  private static String props(NodeEvent ev, Optional<String> tag) {
    StringBuilder out = new StringBuilder();
    ev.getAnchor().ifPresent(a -> out.append(" &").append(a.getValue()));
    tag.ifPresent(t -> out.append(" <").append(t).append(">"));
    return out.toString();
  }

  static List<String> events(String text) {
    LoadSettings settings = LoadSettings.builder().build();
    List<String> out = new ArrayList<>();

    for (Event ev : new Parse(settings).parseString(text)) {
      switch (ev.getEventId()) {
        case StreamStart:
          out.add("+STR");
          break;
        case StreamEnd:
          out.add("-STR");
          break;
        case DocumentStart:
          out.add(((DocumentStartEvent) ev).isExplicit() ? "+DOC ---" : "+DOC");
          break;
        case DocumentEnd:
          out.add(((DocumentEndEvent) ev).isExplicit() ? "-DOC ..." : "-DOC");
          break;
        case MappingStart: {
          CollectionStartEvent c = (CollectionStartEvent) ev;
          out.add("+MAP" + (c.isFlow() ? " {}" : "") + props(c, c.getTag()));
          break;
        }
        case MappingEnd:
          out.add("-MAP");
          break;
        case SequenceStart: {
          CollectionStartEvent c = (CollectionStartEvent) ev;
          out.add("+SEQ" + (c.isFlow() ? " []" : "") + props(c, c.getTag()));
          break;
        }
        case SequenceEnd:
          out.add("-SEQ");
          break;
        case Scalar: {
          ScalarEvent s = (ScalarEvent) ev;
          out.add("=VAL" + props(s, s.getTag()) + " "
              + styleChar(s.getScalarStyle()) + escape(s.getValue()));
          break;
        }
        case Alias:
          out.add("=ALI *" + ((AliasEvent) ev).getAlias().getValue());
          break;
        case Comment:
          // Comments are off by default; ignore them if ever switched on.
          break;
        default:
          throw new IllegalStateException("unhandled event " + ev.getEventId());
      }
    }
    return out;
  }

  // --- batch protocol -------------------------------------------------------
  //
  // stdin:  (<id>\n<nbytes>\n<bytes>)* then "."
  // stdout: ("=== <id> <OK|ERR>\n" <lines>)*

  private static String readLine(InputStream in) throws IOException {
    ByteArrayOutputStream buf = new ByteArrayOutputStream();
    int c;
    while ((c = in.read()) != -1) {
      if (c == '\n') return buf.toString(StandardCharsets.UTF_8);
      buf.write(c);
    }
    return buf.size() == 0 ? null : buf.toString(StandardCharsets.UTF_8);
  }

  private static byte[] readExactly(InputStream in, int n) throws IOException {
    byte[] b = new byte[n];
    int got = 0;
    while (got < n) {
      int r = in.read(b, got, n - got);
      if (r < 0) break;
      got += r;
    }
    return b;
  }

  // --- the loaded-value projection ------------------------------------------
  //
  // No JSON library is on the classpath and one dependency for one serializer
  // is not worth it, so the projection writes JSON directly. Lossy in one
  // direction only: anything JSON cannot represent is rendered so that it
  // cannot accidentally equal a correct answer.
  private static void writeJson(Object v, StringBuilder sb) {
    if (v == null) {
      sb.append("null");
    } else if (v instanceof String) {
      writeJsonString((String) v, sb);
    } else if (v instanceof Boolean) {
      sb.append(v.toString());
    } else if (v instanceof Number) {
      writeJsonNumber((Number) v, sb);
    } else if (v instanceof Map) {
      sb.append('{');
      boolean first = true;
      for (Map.Entry<?, ?> e : ((Map<?, ?>) v).entrySet()) {
        if (!first) sb.append(',');
        first = false;
        writeJsonString(projectKey(e.getKey()), sb);
        sb.append(':');
        writeJson(e.getValue(), sb);
      }
      sb.append('}');
    } else if (v instanceof Set) {
      // !!set loads as a Set; the suite states it as an object of true values.
      sb.append('{');
      boolean first = true;
      for (Object k : (Set<?>) v) {
        if (!first) sb.append(',');
        first = false;
        writeJsonString(projectKey(k), sb);
        sb.append(":true");
      }
      sb.append('}');
    } else if (v instanceof Iterable) {
      sb.append('[');
      boolean first = true;
      for (Object x : (Iterable<?>) v) {
        if (!first) sb.append(',');
        first = false;
        writeJson(x, sb);
      }
      sb.append(']');
    } else if (v instanceof byte[]) {
      // !!binary. The suite states these as strings.
      writeJsonString(new String((byte[]) v, StandardCharsets.UTF_8), sb);
    } else {
      writeJsonString("#<" + v.getClass().getSimpleName() + ">", sb);
    }
  }

  // JSON has no NaN or Infinity. Rendering them as tagged strings keeps a
  // parser that produced one visible instead of emitting invalid JSON.
  private static void writeJsonNumber(Number n, StringBuilder sb) {
    double d = n.doubleValue();
    if (n instanceof Double || n instanceof Float) {
      if (Double.isNaN(d)) { writeJsonString("#<NaN>", sb); return; }
      if (Double.isInfinite(d)) {
        writeJsonString(d > 0 ? "#<Infinity>" : "#<-Infinity>", sb);
        return;
      }
    }
    sb.append(n.toString());
  }

  // JSON object keys are strings; a non-string key is itself often the
  // finding, so it is rendered rather than coerced away.
  private static String projectKey(Object k) {
    if (k instanceof String) return (String) k;
    StringBuilder sb = new StringBuilder();
    writeJson(k, sb);
    return sb.toString();
  }

  private static void writeJsonString(String s, StringBuilder sb) {
    sb.append('"');
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      switch (c) {
        case '"': sb.append("\\\""); break;
        case '\\': sb.append("\\\\"); break;
        case '\n': sb.append("\\n"); break;
        case '\r': sb.append("\\r"); break;
        case '\t': sb.append("\\t"); break;
        case '\b': sb.append("\\b"); break;
        case '\f': sb.append("\\f"); break;
        default:
          if (c < 0x20) {
            sb.append(String.format("\\u%04x", (int) c));
          } else {
            sb.append(c);
          }
      }
    }
    sb.append('"');
  }

  private static List<String> values(String doc) {
    Load load = new Load(LoadSettings.builder().build());
    StringBuilder sb = new StringBuilder();
    sb.append('[');
    boolean first = true;
    for (Object o : load.loadAllFromString(doc)) {
      if (!first) sb.append(',');
      first = false;
      writeJson(o, sb);
    }
    sb.append(']');
    List<String> out = new ArrayList<>();
    out.add(sb.toString());
    return out;
  }

  public static void main(String[] argv) throws IOException {
    boolean jsonMode = false;
    for (String arg : argv) {
      if (arg.equals("--version")) {
        System.out.println(VERSION);
        return;
      }
      if (arg.equals("--json")) {
        jsonMode = true;
      }
    }

    InputStream in = System.in;
    PrintStream out = new PrintStream(System.out, false, StandardCharsets.UTF_8);

    for (;;) {
      String id = readLine(in);
      if (id == null) break;
      id = id.trim();
      if (id.isEmpty()) continue;
      if (id.equals(".")) break;

      String count = readLine(in);
      if (count == null) break;
      int nbytes = Integer.parseInt(count.trim());
      String doc = new String(readExactly(in, nbytes), StandardCharsets.UTF_8);

      try {
        // Materialize before printing the OK header: the Engine parses lazily,
        // so a syntax error surfaces partway through the iteration.
        List<String> lines = jsonMode ? values(doc) : events(doc);
        out.print("=== " + id + " OK\n");
        for (String line : lines) out.print(line + "\n");
      } catch (Throwable t) {
        // Throwable on purpose: a StackOverflowError from a deeply nested
        // document is a parser verdict, not a harness failure.
        String msg = t.getMessage() == null ? "" : t.getMessage();
        int nl = msg.indexOf('\n');
        if (nl >= 0) msg = msg.substring(0, nl);
        out.print("=== " + id + " ERR\n"
            + t.getClass().getSimpleName() + ": " + msg.trim() + "\n");
      }
      out.flush();
    }
    out.flush();
  }
}
