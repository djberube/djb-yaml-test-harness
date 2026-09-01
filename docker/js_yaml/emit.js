// Emits the yaml-test-suite event DSL for each document on stdin.
//
// js-yaml 5 exposes a real event API (`parseEvents`), so this is a direct
// translation rather than a tree walk. Events carry source offsets rather
// than values: a scalar reports valueStart/valueEnd into the original text
// and `getScalarValue` turns that span into the resolved string, applying
// the quoting and chomping rules the span alone does not capture.

const yaml = require('js-yaml');

// With --json, emit the loaded value rather than the event stream: what
// js-yaml resolved the document to, not what its parser built. js-yaml
// implements the YAML 1.2 core schema, so `yes` stays a string where the 1.1
// parsers turn it into a boolean -- a difference the event stream never shows.
const JSON_MODE = process.argv.slice(2).includes('--json');

const { EVENT_DOCUMENT, EVENT_SEQUENCE, EVENT_MAPPING, EVENT_SCALAR,
        EVENT_ALIAS, EVENT_POP, SCALAR_STYLE, COLLECTION_STYLE } = yaml;

const STYLE_CHAR = {
  [SCALAR_STYLE.PLAIN]: ':',
  [SCALAR_STYLE.SINGLE_QUOTED]: "'",
  [SCALAR_STYLE.DOUBLE_QUOTED]: '"',
  [SCALAR_STYLE.LITERAL_BLOCK]: '|',
  [SCALAR_STYLE.FOLDED_BLOCK]: '>'
};

function escape(s) {
  return s
    .replace(/\\/g, '\\\\')
    .replace(/\n/g, '\\n')
    .replace(/\t/g, '\\t')
    .replace(/\r/g, '\\r')
    .replace(/\x08/g, '\\b')
    .replace(/\f/g, '\\f')
    .replace(/\v/g, '\\v')
    .replace(/\0/g, '\\0')
    .replace(/\x07/g, '\\a')
    .replace(/\x1b/g, '\\e');
}

// The suite records fully resolved tags, so a shorthand has to be expanded
// against the handles in scope. `!!foo` is the secondary handle and always
// means tag:yaml.org,2002:foo; `!foo` is the primary handle unless a %TAG
// directive rebound it; `!<...>` is already verbatim.
const DEFAULT_HANDLES = { '!': '!', '!!': 'tag:yaml.org,2002:' };

// A tag suffix may percent-encode characters that are otherwise structural
// (`%21` for `!`). The suite records the decoded form.
function percentDecode(s) {
  return s.replace(/%([0-9A-Fa-f]{2})/g, (_, hex) =>
    String.fromCharCode(parseInt(hex, 16))
  );
}

function resolveTag(raw, handles) {
  if (raw.startsWith('!<') && raw.endsWith('>')) return raw.slice(2, -1);
  if (raw === '!') return '!'; // the non-specific tag

  // Longest handle wins, so a named handle is tried before `!!` before `!`.
  const ordered = Object.keys(handles).sort((a, b) => b.length - a.length);
  for (const handle of ordered) {
    if (raw.startsWith(handle)) {
      return handles[handle] + percentDecode(raw.slice(handle.length));
    }
  }
  return raw;
}

// Anchor and tag come back as spans into the source, so slice them out.
function props(ev, src, handles) {
  let out = '';
  if (ev.anchorStart >= 0 && ev.anchorEnd > ev.anchorStart) {
    out += ' &' + src.slice(ev.anchorStart, ev.anchorEnd);
  }
  if (ev.tagStart >= 0 && ev.tagEnd > ev.tagStart) {
    out += ' <' + resolveTag(src.slice(ev.tagStart, ev.tagEnd), handles) + '>';
  }
  return out;
}

function events(src) {
  const out = ['+STR'];
  // POP closes whichever construct is innermost, so the kinds are stacked.
  const stack = [];
  // %TAG handles are per-document and reset at each document start.
  let handles = Object.assign({}, DEFAULT_HANDLES);

  for (const ev of yaml.parseEvents(src)) {
    switch (ev.type) {
      case EVENT_DOCUMENT:
        handles = Object.assign({}, DEFAULT_HANDLES);
        for (const d of ev.directives || []) {
          if (d.kind === 'tag') handles[d.handle] = d.prefix;
        }
        out.push(ev.explicitStart ? '+DOC ---' : '+DOC');
        stack.push({ kind: 'DOC', explicitEnd: ev.explicitEnd });
        break;

      case EVENT_SEQUENCE:
        out.push('+SEQ' + (ev.style === COLLECTION_STYLE.FLOW ? ' []' : '') + props(ev, src, handles));
        stack.push({ kind: 'SEQ' });
        break;

      case EVENT_MAPPING:
        out.push('+MAP' + (ev.style === COLLECTION_STYLE.FLOW ? ' {}' : '') + props(ev, src, handles));
        stack.push({ kind: 'MAP' });
        break;

      case EVENT_SCALAR: {
        const value = yaml.getScalarValue(src, ev);
        const style = STYLE_CHAR[ev.style] || ':';
        out.push('=VAL' + props(ev, src, handles) + ' ' + style +
                 escape(value === null ? '' : String(value)));
        break;
      }

      case EVENT_ALIAS:
        // An alias reports its name in the anchor span, not a value span.
        out.push('=ALI *' + src.slice(ev.anchorStart, ev.anchorEnd));
        break;

      case EVENT_POP: {
        const open = stack.pop();
        if (!open) break;
        if (open.kind === 'DOC') out.push(open.explicitEnd ? '-DOC ...' : '-DOC');
        else out.push('-' + open.kind);
        break;
      }

      default:
        throw new Error('unhandled event type ' + ev.type);
    }
  }

  out.push('-STR');
  return out;
}

// --- batch protocol ---------------------------------------------------------
//
// stdin:  (<id>\n<nbytes>\n<bytes>)* then "."
// stdout: ("=== <id> <OK|ERR>\n" <lines>)*

// Project a loaded value onto JSON's type set. Lossy in one direction only:
// anything JSON cannot represent is rendered so it cannot accidentally equal a
// correct answer.
function project(v) {
  if (v === null || v === undefined) return null;
  if (Array.isArray(v)) return v.map(project);
  if (v instanceof Date) return v.toISOString();
  if (v instanceof RegExp) return '#<RegExp ' + String(v) + '>';
  if (v instanceof Map) {
    const o = {};
    for (const [k, val] of v) o[projectKey(k)] = project(val);
    return o;
  }
  if (v instanceof Set) {
    const o = {};
    for (const k of v) o[projectKey(k)] = true;
    return o;
  }
  if (typeof v === 'number' || typeof v === 'string' || typeof v === 'boolean') return v;
  if (typeof v === 'object') {
    const o = {};
    for (const k of Object.keys(v)) o[projectKey(k)] = project(v[k]);
    return o;
  }
  return '#<' + typeof v + '>';
}

// JSON object keys are strings; a non-string key is itself often the finding,
// so it is rendered rather than coerced away.
function projectKey(k) {
  const p = project(k);
  return typeof p === 'string' ? p : JSON.stringify(p);
}

function values(src) {
  const docs = [];
  yaml.loadAll(src, (d) => docs.push(project(d === undefined ? null : d)));
  return docs;
}

function main() {
  const chunks = [];
  process.stdin.on('data', (c) => chunks.push(c));
  process.stdin.on('end', () => {
    const buf = Buffer.concat(chunks);
    let pos = 0;

    const readLine = () => {
      const nl = buf.indexOf(0x0a, pos);
      if (nl === -1) return null;
      const s = buf.slice(pos, nl).toString('utf8');
      pos = nl + 1;
      return s;
    };

    const out = [];
    for (;;) {
      const id = readLine();
      if (id === null || id.trim() === '.') break;
      const n = parseInt(readLine(), 10);
      const doc = buf.slice(pos, pos + n).toString('utf8');
      pos += n;

      try {
        // Produce the lines before writing the OK header: a throw partway
        // through must not leave a header claiming success.
        const lines = JSON_MODE ? [JSON.stringify(values(doc))] : events(doc);
        out.push('=== ' + id.trim() + ' OK');
        for (const line of lines) out.push(line);
      } catch (err) {
        const msg = String((err && err.message) || err).split('\n')[0].trim();
        out.push('=== ' + id.trim() + ' ERR');
        out.push(((err && err.name) || 'Error') + ': ' + msg);
      }
    }
    process.stdout.write(out.join('\n') + '\n');
  });
}

main();
