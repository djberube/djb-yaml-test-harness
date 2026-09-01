# djb-yaml-test-harness

Runs the [yaml-test-suite](https://github.com/yaml/yaml-test-suite) against nine
YAML parsers across seven languages and reports where each one disagrees with
the spec — and with the others.

```
parser                pass   pass%  accepts-invalid  wrong-events  rejects-valid
--------------------  ----  ------  ---------------  ------------  -------------
Psych (libyaml)        330   82.1%               16             5             51
Psych (libfyaml)       402  100.0%                .             .              .
PyYAML (pure)          329   81.8%               14             5             54
PyYAML (CSafeLoader)   330   82.1%               16             5             51
rapidyaml              377   93.8%                4             3             18
js-yaml                402  100.0%                .             .              .
go-yaml v3             323   80.3%               15             6             58
saphyr                 402  100.0%                .             .              .
SnakeYAML Engine       338   84.1%                6             2             56
```

Every parser runs in its own container against a pinned library version, so a
number in that table is attributable to a specific build rather than to
whatever happened to be installed.

Two rows in that table are the same Ruby, the same Psych, and the same emitter,
differing only in which C library is linked in. Two others are the same PyYAML
differing only in the Loader class — and `pyyaml-c` matches `psych` in every
column, because underneath both is the same libyaml.

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

**This measures the parser layer only.** The event DSL records tags but not
resolved native types, so a parser can score well while still resolving `no` to
`false` or `20:03:20` to `72200`. Schema conformance is a separate question this
harness does not answer.

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
parser                             pass  pass%  accepts-invalid  wrong-events  rejects-valid
---------------------------------  ----  -----  ---------------  ------------  -------------
Psych (libyaml)                     330  82.1%               16             5             51
Psych 3.3.2 (ly0.2.5, rb3.4)        330  82.1%               16             5             51
Psych 4.0.4 (ly0.2.5, rb3.4)        330  82.1%               16             5             51
Psych 5.0.1 (ly0.2.5, rb3.4)        330  82.1%               16             5             51
Psych 5.1.2 (ly0.2.5, rb3.4)        330  82.1%               16             5             51
Psych 5.2.2 (ly0.2.1, rb3.4)        324  80.6%               14             5             59
Psych 5.2.2 (ly0.2.2, rb3.4)        325  80.8%               14             5             58
Psych 5.2.2 (ly0.2.6-rc.1, rb3.4)   330  82.1%               16             5             51
Psych 5.2.2 (ly0.2.5, rb3.1)        330  82.1%               16             5             51
Psych 5.2.2 (ly0.2.5, rb3.5-rc)     330  82.1%               16             5             51
```

Five psych versions spanning 3.3.2 to 5.2.2 score identically, and not merely in
total: they fail the same 72 cases with the same verdict on each. Three Rubies
from 3.1 to the 3.5 release candidate do too. Everything that separates one row
from another in this table is libyaml.

That is a narrower claim than it looks, and the narrowing matters. Psych 4's
`load`-is-`safe_load` change and psych 5's schema work are real, and they are
invisible here because this harness compares event streams — the layer where
Psych is a thin binding over C. Where psych versions *do* differ is in what they
resolve those events to, which is the [schema question this harness does not
answer](#what-it-measures).

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
none of it is attributable to Ruby.

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

## Reports

Each run writes four files to `reports/`:

- **`report.md`** — summary table, per-case matrix, and a detail list per parser
- **`report.json`** — the same data, with the full expected-vs-actual event
  streams for every failure
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
| `YAML_SUITE_REF` | `data-2022-01-17` | which suite tag to check out |
| `YAML_HARNESS_OUT` | `reports` | where reports are written |
| `YAML_HARNESS_TIMEOUT` | `10` | per-case seconds before a batch is abandoned |
| `YAML_HARNESS_BATCH` | `64` | cases per container invocation |

The suite ref is pinned rather than floating: an unpinned corpus would make two
runs of the same harness disagree for reasons that have nothing to do with the
parsers.

## License

MIT.
