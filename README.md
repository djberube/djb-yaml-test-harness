# djb-yaml-test-harness

Runs the [yaml-test-suite](https://github.com/yaml/yaml-test-suite) against nine
YAML parsers across seven languages and reports where each one disagrees with
the spec — and with the others.

The suite states two expectations per case, and this harness scores both
separately. `tree:` is the event stream the parser should build; `json:` is the
value the library should hand back. They are different questions, and a parser
can pass one while failing the other.

**Event streams** — what the parser built:

```
parser                pass   pass%  accepts-invalid  wrong-events  rejects-valid
--------------------  ----  ------  ---------------  ------------  -------------
Psych (libyaml)        331   81.7%               16             4             54
Psych (libfyaml)       403   99.5%                .             .              2
PyYAML (pure)          331   81.7%               14             4             56
PyYAML (CSafeLoader)   331   81.7%               16             4             54
rapidyaml              379   93.6%                4             3             19
js-yaml                404   99.8%                .             .              1
go-yaml v3             324   80.0%               15             5             61
saphyr                 403   99.5%                .             .              2
SnakeYAML Engine       339   83.7%                6             1             59
```

**Loaded values** — what the library resolved that into, over the 365 cases the
suite states a `json:` for:

```
parser                pass  pass%  accepts-invalid  wrong-value  rejects-valid
--------------------  ----  -----  ---------------  -----------  -------------
Psych (libyaml)        301  82.5%               16           11             37
Psych (libfyaml)       353  96.7%                .           11              1
PyYAML (pure)          287  78.6%               12           10             56
PyYAML (CSafeLoader)   290  79.5%               15           10             50
rapidyaml              335  91.8%                4           18              8
js-yaml                349  95.6%                .            .             16
go-yaml v3             299  81.9%               15            7             44
saphyr                 348  95.3%                .           17              .
SnakeYAML Engine       298  81.6%                6            3             58
```

The gap between the two tables is the interesting part. Psych on libfyaml parses
almost everything correctly — 403 of 405 event streams — and still gets eleven
values wrong, the same count as the libyaml build. Swapping the C parser fixes
the syntax layer and leaves `Psych::ScalarScanner` untouched on top of it.
saphyr makes the same trade more sharply: it rejects nothing and mis-parses
nothing, then resolves 17 documents to the wrong value. js-yaml is the only
parser here with no wrong-value cases at all.

Every parser runs in its own container against a pinned library version, so a
number in those tables is attributable to a specific build rather than to
whatever happened to be installed.

Two rows are the same Ruby, the same Psych, and the same emitter, differing only
in which C library is linked in. Two others are the same PyYAML differing only
in the Loader class — and `pyyaml-c` matches `psych` in every column, because
underneath both is the same libyaml.

## Quick start

```sh
./bin/conform
```

That is the whole setup. On first run it clones the test suite into
`vendor/` (gitignored) and builds whichever container images are missing.
Later runs reuse both.

```sh
./bin/conform --list                      # what parsers are configured
./bin/conform --matrix-only               # the Psych version matrix
./bin/conform --values                    # score events and loaded values
./bin/conform --values-only               # score loaded values instead
./bin/conform --no-agreement              # skip the pairwise agreement tables
./bin/conform --only psych,js-yaml        # just these two
./bin/conform --case '4MUZ|DK95'          # just cases matching this regex
./bin/conform --no-report                 # terminal only
./bin/conform --out /tmp/run1             # write reports elsewhere
```

Requirements: Ruby (any 3.x) and Docker. Nothing else — the parsers and their
toolchains live in the images.

## What it measures

Each parser emits the suite's own event DSL for every document, and that stream
is compared against the `test.event` the suite ships. This is how yaml-test-suite
scores parsers, so the numbers are comparable to published ones.

A failure is one of three things:

| kind | meaning | why it matters |
|---|---|---|
| `rejects-valid` | raised on a document the suite says is valid | your config file is fine and the parser won't load it |
| `accepts-invalid` | parsed a document the suite says is ill-formed | a typo becomes data instead of an exception |
| `wrong-events` | parsed, but produced a different tree | the quietest failure, and the worst |

A fourth, `harness-error`, means the runner itself failed. That is a bug here,
not a parser verdict, and is reported separately so it never inflates a
parser's failure count.

### The two scores

The event DSL records tags but not resolved native types, so an event-stream
pass says nothing about what the library hands back. `bin/conform --values` runs
the second pass, comparing the loaded value against the suite's `json:`.

That is where Psych's Ruby-isms show up, and they are not fixed by changing the
C parser:

| case | expected | Psych gives |
|---|---|---|
| `FBC9` | `":foo"` | `:foo`, a Symbol |
| `Y2GN` | `"value"` | `:"chor value"` |
| `U9NS` | `"20:03:20"` | `72200`, sexagesimal |

`FBC9`, `S7BG`, `U9NS` and four others fail on **both** backends. The suite ships
the correct event stream for all of them, and Psych emits it — the value is
wrong one layer later, in `Psych::ScalarScanner`.

Only cases with a `json:` are scored in the value run. The suite omits it where a
document has no meaningful JSON projection (an empty stream, a duplicate key, a
value JSON cannot represent), and counting "no expectation" as a pass would
inflate every parser by the same ~40 cases.

## Parsers

| id | parser | language | notes |
|---|---|---|---|
| `psych` | Psych | Ruby | stdlib YAML, libyaml underneath |
| `psych-fyaml` | Psych | Ruby | built `--enable-libfyaml`, the opt-in 1.2 backend |
| `pyyaml` | PyYAML | Python | pure-Python parser |
| `pyyaml-c` | PyYAML | Python | CSafeLoader — same libyaml Psych uses |
| `rapidyaml` | rapidyaml | C++ | via its Python bindings |
| `js-yaml` | js-yaml | JavaScript | v5, which exposes a real event API |
| `go-yaml` | go-yaml v3 | Go | the parser behind most Go tooling |
| `saphyr` | saphyr | Rust | maintained fork of yaml-rust |
| `snakeyaml` | SnakeYAML Engine | Java | the YAML 1.2 rewrite |

Plus nine more under `--matrix-only` that vary Ruby, psych, and libyaml
independently; see [the Psych version matrix](#the-psych-version-matrix).
`bin/conform --list` prints both groups.

The pairs are the point. `psych` and `psych-fyaml` differ only in which C parser
is linked in; `pyyaml` and `pyyaml-c` differ only in which Loader class runs.
Any divergence within a pair is attributable to the C library rather than to the
binding — which is exactly the distinction that is hard to make from the outside.

## The Psych version matrix

"Psych 5.2.2 does X" underspecifies the thing. Psych's behaviour is the product
of three separately-versioned parts — the Ruby it runs on, the psych gem, and
the libyaml it links against — and the version people quote is only the middle
one. `bin/conform --matrix-only` builds nine images that vary one part at a time
from a `ruby 3.4 / psych 5.2.2 / libyaml 0.2.5` baseline, so a difference between
two rows is attributable to the one thing that differs.

```
                                   ---- events ----   ---- values ----
parser                             pass  pass%        pass  pass%   wrong-value
---------------------------------  ----  -----        ----  -----   -----------
Psych (libyaml)                     331  81.7%         301  82.5%            11
Psych 3.3.2 (ly0.2.5, rb3.4)        331  81.7%         301  82.5%            11
Psych 4.0.4 (ly0.2.5, rb3.4)        331  81.7%         301  82.5%            11
Psych 5.0.1 (ly0.2.5, rb3.4)        331  81.7%         301  82.5%            11
Psych 5.1.2 (ly0.2.5, rb3.4)        331  81.7%         301  82.5%            11
Psych 5.2.2 (ly0.2.1, rb3.4)        325  80.2%         295  80.8%            11
Psych 5.2.2 (ly0.2.2, rb3.4)        326  80.5%         296  81.1%            11
Psych 5.2.2 (ly0.2.6-rc.1, rb3.4)   331  81.7%         301  82.5%            11
Psych 5.2.2 (ly0.2.5, rb3.1)        331  81.7%         301  82.5%            11
Psych 5.2.2 (ly0.2.5, rb3.5-rc)     331  81.7%         301  82.5%            11
```

Five psych versions spanning 3.3.2 to 5.2.2 score identically, and not merely in
total: they fail the same cases with the same verdict on each. Three Rubies from
3.1 to the 3.5 release candidate do too. Everything that separates one row from
another is libyaml.

The value column is the interesting confirmation. Scoring what Psych *resolves*
rather than what it parses was the obvious place for psych versions to diverge —
psych 4's `load`-is-`safe_load` change and psych 5's schema work are real
changes — and they do not move this number either. All eleven wrong-value cases
are the same eleven on every row, including psych 3.3.2. `Psych::ScalarScanner`
has been coercing `:foo` to a Symbol and `20:03:20` to `72200` across the entire
3.x-to-5.x range.

Across libyaml the movement is directional but not monotone:

| case | 0.2.1 | 0.2.2 | 0.2.5 |
|---|---|---|---|
| `UDM2` | rejects-valid | pass | pass |
| `27NA` `6ZKB` `9DXL` `DK95#7` `JR7V` `RTP8` `WZ62` | rejects-valid | rejects-valid | pass |
| `U99R` | accepts-invalid | accepts-invalid | pass |
| `EB22` `MUS6#1` `RHX7` | pass | pass | accepts-invalid |

0.2.5 fixes nine cases the older builds get wrong and regresses three, accepting
documents the suite marks ill-formed that 0.2.1 correctly rejected. The 0.2.6
release candidate changes nothing either way. Upgrading libyaml is a net win of
six cases, not a clean one — and since these are the same psych gem throughout,
none of it is attributable to Ruby. The same nine-fixed, three-regressed split
shows up in the value run, because these are parse-layer differences that the
value run inherits.

### Adding a combination

`COMBOS` in `lib/parsers.rb` is the table; the Dockerfiles are generated from it.

```sh
$EDITOR lib/parsers.rb
ruby docker/psych_matrix/generate.rb
./bin/conform --only libyaml-0.2.1
```

One Dockerfile per combination, checked in, rather than one parameterised file
built with `--build-arg`: build args leave no trace in the image, so an image
built from them cannot be traced back to what produced it.

Not every combination is valid. Psych 4 and 5 need Ruby 3.x, Ruby 2.7 and 3.0
have no bookworm base image, and libyaml before 0.2.1 lacks API psych 5 calls.
Each image asserts its own `Psych::VERSION` and `Psych::LIBYAML_VERSION` at build
time, so an invalid combination fails the build instead of quietly reporting a
row that says something other than what it claims.

## Agreement

Conformance asks whether a parser matched the suite. Agreement asks whether two
parsers matched *each other* — a different question with a different answer.
Two libraries can fail the same case in two different ways, or agree exactly
while both being wrong; neither shows up in a pass/fail tally. This is the
practical question behind "will this file survive a trip through another
language's parser".

Pairwise agreement on **event streams**, as a percentage of the 405 cases:

```
parser  psych  fyaml  pyyaml  pyy-c  ryml  jsyaml  go  saphyr  snake
------  -----  -----  ------  -----  ----  ------  --  ------  -----
psych       .     82      85    100    77      80  94      78     84
fyaml      82      .      79     79    89     100  81      92     80
pyyaml     85     79       .     94    76      82  85      78     92
pyy-c     100     79      94      .    76      83  88      79     87
ryml       77     89      76     76     .      88  77      88     78
jsyaml     80    100      82     83    88       .  78     100     85
go         94     81      85     88    77      78   .      78     85
saphyr     78     92      78     79    88     100  78       .     81
snake      84     80      92     87    78      85  85      81      .
```

All nine produce identical output on 288 of 405 cases (71.1%); 117 are
contested.

`psych` and `pyyaml-c` agree on **100%** — different languages, different
bindings, byte-identical event streams on all 405 cases, because underneath both
is the same libyaml. That is the cleanest evidence in this repo that the binding
contributes nothing and the C library decides everything.

On values that pair drops to 90.4%. Same parser, same events, and the Ruby and
Python schema layers still disagree about 35 documents.

The other 100% cell is `psych-fyaml` with `js-yaml` and `saphyr` — three
implementations in three languages that share no code, converging because they
all target YAML 1.2 rather than 1.1.

Reading the low end is just as useful: `rapidyaml` sits at 75-78% against the
1.1 parsers, which is what a parser aimed at a different spec version looks
like from the outside.

The reports list the contested cases with who is in which camp, and name the
first event line the camps differ on:

```
case     camps  split
-------  -----  ---------------------------------------------------------------
4ABK         3  =VAL :omitted value: fyaml pyyaml ryml jsyaml saphyr snake  |
                error: psych pyy-c  |  =VAL :omitted value:: go
Y2GN         2  =VAL &an ::chor value: psych go  |  =VAL &an:chor :value: fyaml jsyaml
```

`Y2GN` is an anchor with a colon in its name. Psych and go-yaml read the anchor
as `&an` and the value as `:chor value`; libfyaml and js-yaml read `&an:chor`
with the value `value`. Both camps parse it. Only one is right.

Pass `--no-agreement` to skip these tables.

## Reports

Each scored run writes four files to `reports/`. With `--values` both runs are
written, suffixed `-events` and `-value`:

- **`report.md`** — summary table, per-case matrix, and a detail list per parser
- **`report.json`** — the same data, plus every row's actual output (passes
  included) and the computed agreement blocks. The failures list answers "was it
  right"; the results list answers "what did it say", which is not derivable
  from the first and is what the agreement statistics are computed from
- **`matrix.csv`** — case × parser, for a spreadsheet
- **`report.txt`** — the terminal output, saved

The per-case matrix is the part worth reading. A row where every parser fails is
a hard corner of the spec; a row where one parser fails alone is that parser's
bug. Reading down the `psych` and `pyyaml-c` columns shows the libyaml family
failing in lockstep.

## Adding a parser

1. Make a directory under `docker/` with a `Dockerfile` and an emitter.
2. Add an entry to `lib/parsers.rb`.

The emitter reads a batch of documents on stdin and writes event streams on
stdout:

```
stdin:  (<id>\n<nbytes>\n<document bytes>)*  then a line reading "."
stdout: ("=== <id> OK\n" <event lines>)  or  ("=== <id> ERR\n" <one-line message>)
```

Byte lengths rather than delimiters, because YAML documents contain every
delimiter one might pick — including lines of dots and dashes.

With `--json` the emitter writes one line per case instead: the loaded value of
the whole stream, as a JSON array with one element per document. Mark the parser
`value: true` in `lib/parsers.rb` once it does; the value run skips any parser
that does not rather than reporting a zero for a mode it cannot answer.

Use the library's own loader for that, not a schema reimplemented in the
emitter — the number is supposed to describe the library. Where a language has
no loader, use whatever the library does expose: `docker/rapidyaml/emit.py`
calls ryml's `emit_json`, which is rapidyaml applying its own scalar resolution.

The projection onto JSON's type set must be lossy in one direction only. A Ruby
Symbol is rendered `#<Symbol :foo>`, not `":foo"` — rendering it as the string
would make the projection launder Psych's `:foo` coercion into a pass, which is
exactly the bug the value run exists to find. Same for NaN, Infinity, and any
object JSON cannot represent.

`docker/js_yaml/emit.js` is the cleanest reference: js-yaml exposes a genuine
event API, so it translates events one-for-one. `docker/psych/emit.rb` shows the
other shape, reconstructing events from a parse tree, which is what you need when
the library gives you no event API.

`docker/go_yaml/` shows the third case. go-yaml's parser produces a full
libyaml-style event stream internally but exports only `yaml.Node`, a tree that
has already dropped the explicit `---`/`...` markers and the difference between a
written and an inferred tag. So the package is vendored under `internal/goyaml`
with one added file re-exporting those events; the upstream sources are
unmodified and their LICENSE and NOTICE are kept alongside.

Emitter details that are easy to get wrong, all of which the suite checks:

- Collection style comes **before** the anchor and tag: `+SEQ [] &key`, not
  `+SEQ &key []`.
- Tags are recorded fully resolved. `!!str` → `tag:yaml.org,2002:str`, `!<foo>`
  → `foo`, bare `!` stays `!`, and `%TAG` handles apply per document.
- Percent escapes in a tag suffix are decoded: `%21` → `!`.
- Emit a tag only when the document actually stated one. Libraries that resolve
  a tag onto every scalar need that filtered out.
- Escape `\\` first, then `\n \t \r \b \f \v \0 \a \e`.

## Configuration

Environment variables, all optional:

| variable | default | meaning |
|---|---|---|
| `YAML_SUITE_REF` | `da267a5c` | which suite commit to check out |
| `YAML_HARNESS_OUT` | `reports` | where reports are written |
| `YAML_HARNESS_TIMEOUT` | `10` | per-case seconds before a batch is abandoned |
| `YAML_HARNESS_BATCH` | `64` | cases per container invocation |

The suite ref is pinned rather than floating: an unpinned corpus would make two
runs of the same harness disagree for reasons that have nothing to do with the
parsers.

Cases are read from the suite's `src/` directory — 351 files, each an ordinary
YAML sequence holding `yaml:`, `tree:` and `json:` together — rather than from
one of the generated `data-*` tags. The tags are snapshots of this same content,
but the newest is `data-2022-01-17`, four years and 400+ commits behind, and the
generated form drops `json:` for a third of the cases it applies to. Reading
`src/` is what makes the value run possible.

## License

MIT.
