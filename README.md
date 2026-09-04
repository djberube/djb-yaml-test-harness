# djb-yaml-test-harness

YAML is usually described as a single format, and most of the time it behaves
like one. Write a config file, hand it to a library, get a hash back. The
trouble starts when the same file has to travel: written by a Ruby service,
read by a Go sidecar, validated by a Python job. Each of those reaches for a
different parser, and the parsers do not agree — not on which documents are
well-formed, and not on what a well-formed document means.

This harness runs the [yaml-test-suite](https://github.com/yaml/yaml-test-suite)
against ten YAML parsers across eight languages — plus two reference parsers
generated from the spec grammar itself — and reports where each one disagrees
with the spec, and with the others.

The suite states two expectations per case, and we score both separately.
`tree:` is the event stream the parser should build; `json:` is the value the
library should hand back. They are different questions, and a parser can pass
one while failing the other.

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
YAMLStar               404   99.8%                .             .              1
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
YAMLStar               352  96.4%                .            1             12
```

Reading the two tables against each other is where the useful information is.
Psych on libfyaml parses almost everything correctly — 403 of 405 event streams
— and still gets eleven values wrong, the same count as the libyaml build.
Swapping the C parser fixes the syntax layer and leaves `Psych::ScalarScanner`
untouched on top of it. saphyr makes the same trade more sharply: it rejects
nothing and mis-parses nothing, then resolves 17 documents to the wrong value.
js-yaml is the only parser here with no wrong-value cases at all, and YAMLStar
comes within one of it. Both get there partly by declining to answer: js-yaml
raises on 16 of the 365 valued cases and YAMLStar on 12. A parser that refuses a
document cannot resolve it wrongly, so the wrong-value column is worth reading
next to the rejects-valid one rather than on its own.

Every parser runs in its own container against a pinned library version, so a
number in those tables is attributable to a specific build rather than to
whatever happened to be installed. The figures shown here come from a run in
2026; re-running `bin/conform` on a checkout with newer pins will produce its
own, and the point of pinning is that both runs remain explicable.

The rows are also arranged so that some of them can be read as controlled
comparisons. Two are the same Ruby, the same Psych, and the same emitter,
differing only in which C library is linked in. Two others are the same PyYAML
differing only in the Loader class — and `pyyaml-c` matches `psych` in every
column, because underneath both is the same libyaml.

## Quick start

```sh
./bin/conform
```

There is no separate install step. On first run the harness clones the test
suite into `vendor/` (gitignored) and builds whichever container images are
missing; later runs reuse both. Expect the first run to take a while, since it
is building images across nine language toolchains, and the `psych-fyaml` image
compiles libfyaml from source.

```sh
./bin/conform --list                      # what parsers are configured
./bin/conform --matrix-only               # the Psych version matrix
./bin/conform --values                    # score events and loaded values
./bin/conform --values-only               # score loaded values instead
./bin/conform --no-agreement              # skip the pairwise agreement tables
./bin/conform --only psych,js-yaml        # just these two
./bin/conform --case '4MUZ|DK95'          # just cases matching this regex
./bin/conform --custom-only               # just the local cases in data/custom_cases/
./bin/conform --no-custom                 # skip them
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

One may wonder why a second score is needed at all: if a parser built the right
event stream, has it not already got the document right? The answer is that the
event DSL records tags but not resolved native types. In `FBC9`, for instance,
the suite expects the plain scalar `:foo` — written `=VAL ::foo`, since the DSL
marks plain scalars with a leading colon of its own — and Psych emits exactly
that, then hands back a Ruby Symbol rather than the string. `bin/conform
--values` runs the second pass, comparing the loaded value against the suite's
`json:`.

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

### What it does not measure

Worth being clear about the boundaries, since a pass percentage invites more
weight than it can carry.

The harness scores reading, not writing. Every parser here is asked to consume
documents; none is asked to emit them, so the suite's `dump:` expectations go
unused and round-tripping is out of scope entirely. A library can score well
above and still produce YAML that its own parser reads back differently.

Nothing here measures performance, memory, or resistance to hostile input.
rapidyaml and libyaml are fast, the reference parsers are extremely slow, and
none of that appears in any table. Neither do the qualities you would actually
weigh when picking a library — API design, error message quality, maintenance
activity, security history. A parser's conformance number is one input to that
decision and not a ranking.

The corpus is also the suite's, and the suite is built from the corners of the
grammar rather than from what turns up in configuration files. This matters for
how the percentages read: a parser at 80% is not failing one document in five
that you hand it, it is failing one in five of a set assembled specifically from
hard cases. `data/custom_cases/` exists partly to ask the other question, on
documents you choose.

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
| `yamlstar` | YAMLStar | Clojure | pure-Clojure 1.2 stack, parser and loader separate |
| `ref-js` | reference parser | JavaScript | generated from the YAML 1.2 spec grammar |
| `ref-perl` | reference parser | Perl | the same grammar, second language |

Plus nine more under `--matrix-only` that vary Ruby, psych, and libyaml
independently; see [the Psych version matrix](#the-psych-version-matrix).
`bin/conform --list` prints both groups.

Two of these rows exist to be read as a pair, and two more as another. `psych`
and `psych-fyaml` differ only in which C parser is linked in; `pyyaml` and
`pyyaml-c` differ only in which Loader class runs. Any divergence within a pair
is therefore attributable to the C library rather than to the binding — a
distinction that is otherwise difficult to make from the outside, since a bug
report says "Psych got this wrong" whether the fault lies in the Ruby or in the
C.

### The reference rows

`ref-js` and `ref-perl` come from
[yaml/yaml-reference-parser](https://github.com/yaml/yaml-reference-parser), and
they are not libraries anyone ships. They are *generated* from the YAML 1.2 spec
grammar — one function per BNF production — which makes them about as close to
an executable copy of the spec as exists, and slow enough that nobody would read
a config file with one.

They are here as controls. Every other row is a hand-written approximation of
the same grammar, so the reference rows turn a failure into a diagnosis: a case
some parser fails and the reference passes is that parser deviating from the
spec, and a case the reference fails too is a place where the spec, the suite,
and the generated grammar do not agree with each other. The suite's
expectations alone cannot tell those apart.

Both rows are one grammar rendered into two languages, pinned to the same
commit, so a disagreement *between them* is the generator or the host language
rather than anyone's reading of the spec. In practice they do not disagree: both
score 404 of 405, failing the same single case, which is roughly the result you
would hope for from a control and a mild reassurance that the suite and the
grammar are describing the same language.

They score event streams only. A reference parser parses and stops — no schema,
no tag resolution to native types, no loader — so there is nothing to ask for a
value, and the value run skips them rather than reporting a zero for a question
they do not answer.

## The Psych version matrix

Bug reports about YAML in Ruby tend to name a psych version: "Psych 5.2.2 does
X." That underspecifies the thing considerably. Psych's behaviour is the product
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

Two practical conclusions follow. If you are chasing a YAML parsing difference
between two machines, the psych version is generally the wrong place to look;
check `Psych::LIBYAML_VERSION` on both first. And if the behaviour you need is
in `Psych::ScalarScanner` rather than the parser — the Symbol coercion, the
sexagesimal handling — no combination in this matrix will give it to you, which
is the case for reaching past `YAML.load` to `Psych.parse` and resolving
scalars yourself.

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
parser  psych  fyaml  pyyaml  pyy-c  ryml  jsyaml  go  saphyr  snake  ystar
------  -----  -----  ------  -----  ----  ------  --  ------  -----  -----
psych       .     82      93    100    77      82  97      82     90     82
fyaml      82      .      81     82    94     100  80     100     84    100
pyyaml     93     81       .     93    78      82  92      82     95     82
pyy-c     100     82      93      .    77      82  97      82     90     82
ryml       77     94      78     77     .      94  75      94     80     94
jsyaml     82    100      82     82    94       .  80     100     84    100
go         97     80      92     97    75      80   .      80     89     80
saphyr     82    100      82     82    94     100  80       .     84    100
snake      90     84      95     90    80      84  89      84      .     84
ystar      82    100      82     82    94     100  80     100     84      .
```

All twelve rows, the two reference parsers included, produce identical output on
288 of 405 cases (71.1%); the remaining 117 are contested.

`psych` and `pyyaml-c` agree on **100%** — different languages, different
bindings, byte-identical event streams on all 405 cases, because underneath both
is the same libyaml. At the parse layer, then, the binding contributes nothing
we can measure; the C library decides the outcome.

On values that pair drops to 90.4%. Same parser, same events, and the Ruby and
Python schema layers still disagree about 35 documents. Which is worth keeping
in mind when a YAML file has to survive a trip between the two: the syntax will
travel intact, and the types may not.

The rest of the 100% cells form a single block: `psych-fyaml`, `js-yaml`,
`saphyr` and `yamlstar` agree with each other, and with both reference parsers,
on all 405 cases. That is six implementations in six languages — Ruby, JavaScript,
Rust, Clojure, and the generated JS and Perl — sharing no code and converging
exactly, because they all target YAML 1.2 rather than 1.1. Agreement with the
reference rows is the part that makes this more than a coincidence: the four
libraries are not merely agreeing with each other, they are agreeing with the
grammar.

Which suggests a practical reading of the whole table. The spread is not a
gradient of quality so much as a split into two families, and a parser's
agreement score is mostly a statement about which YAML version it implements.

The low end of the table repays reading too. `rapidyaml` sits at 75-78% against
the 1.1 parsers, which is what a parser aimed at a different spec version looks
like from the outside — not a quality judgment on any row, but a real
compatibility cost if a file has to cross between them.

The reports list the contested cases with who is in which camp, and name the
first event line the camps differ on:

```
case     camps  split
-------  -----  ---------------------------------------------------------------
4ABK         3  =VAL :omitted value: fyaml pyyaml ryml jsyaml saphyr snake
                ystar ref-js ref-pe  ·  error: psych pyy-c  ·
                =VAL :omitted value:: go
Y2GN         2  =VAL &an ::chor value: psych go  ·  =VAL &an:chor :value: fyaml jsyaml
```

`Y2GN` is an anchor with a colon in its name. Psych and go-yaml read the anchor
as `&an` and the value as `:chor value`; libfyaml and js-yaml read `&an:chor`
with the value `value`. Both camps parse it without complaint, which is what
makes this the failure mode worth worrying about — nobody gets an exception,
and two services disagree about what the document said.

Here the control rows earn their keep. The suite expects `&an:chor`, and both
reference parsers produce it, so the second camp is following the grammar and
Psych and go-yaml are not. Without those rows this case would look like an open
question rather than a settled one.

Pass `--no-agreement` to skip these tables.

## Reports

Each scored run writes four files to `reports/`, plus a shared `cases/`
directory. With `--values` both runs are written, suffixed `-events` and
`-value`:

- **`report.md`** — summary table, per-case matrix, and a detail list per parser
- **`report.json`** — the same data, plus every row's actual output (passes
  included) and the computed agreement blocks. The failures list answers "was it
  right"; the results list answers "what did it say", which is not derivable
  from the first and is what the agreement statistics are computed from
- **`matrix.csv`** — case × parser, for a spreadsheet
- **`report.txt`** — the terminal output, saved

Of these, the per-case matrix in `report.md` is where most questions get
answered. A row where every parser fails is a hard corner of the spec; a row
where one parser fails alone is that parser's bug. Reading down the `psych` and
`pyyaml-c` columns shows the libyaml family failing in lockstep.

### Per-case files

`reports/cases/` holds one Markdown file per failing case — `4ABK.md`, `A2M4.md`
and so on, with `#` in a case id written as `-` so `4MUZ#0` becomes `4MUZ-0.md`.
Where the tables above are organized by parser, these are the transpose: one
case, every parser's verdict on it side by side.

Each file carries the document that produced the failure, what the suite
expected, a table of which parsers failed and how, and the distinct outputs the
failing parsers produced — grouped, so nine parsers making the same two mistakes
print two streams rather than nine. `reports/cases/README.md` indexes them,
worst case first.

Both scored runs land in the same file rather than one directory per mode. A
case that fails the event run and passes the value run is a specific and
interesting thing — the parser built the wrong stream and still resolved the
right object — and splitting the two would hide exactly that.

Only failing cases get a file. The cases every parser passes have nothing to say,
and writing them would bury the ones that do.

## Custom cases

`data/custom_cases/` holds documents this project cares about that the suite
does not cover — a directive nobody implements, a construct that turned up in a
real config file, whatever the last bug report was about. Each file is one
document, verbatim: no wrapper, no metadata, whatever bytes are in
`data/custom_cases/foo.yml` are the bytes handed to every parser.

Custom cases deliberately carry **no expectation**. The suite states what a
parser should build and the harness scores against it; a custom case asks the
weaker question of what each parser *does*, with no claim about which answer is
right. There is no oracle here, so there is nothing to pass or fail — which
turns out to be the more useful question when you are holding a document from a
real system and want to know who will read it your way.

They also never enter the scored totals. A pass rate is a number against a fixed
published corpus, and quietly folding local cases into it would make "81.7%"
mean something different in this checkout than anywhere else. Custom cases run
after the scored runs, report into their own directory, and cannot move any
number in the tables above.

Adding one is a matter of dropping a file in:

```sh
printf 'yes: no\n' > data/custom_cases/yes_no.yml
./bin/conform --custom-only --values
```

An optional first line of `# name: something` becomes the case's label in the
report and is stripped from the document before it is handed to any parser — it
is metadata, not content, and a `%YAML` or `%TAG` directive has to precede
everything in its document, so a comment left above one would quietly change
what the case tests. The filename is the case id either way.

### The custom report

`reports/custom_cases/` gets one Markdown file per document, plus a `README.md`
index and a `custom_cases.json`. A page carries the document, a table of what
each parser did with it, and the distinct outputs grouped — twelve parsers
usually produce two or three distinct answers, and printing the same stream
twelve times would bury the disagreement.

These pages are organized around **camps**: how many distinct things the field
produced for a given document. One camp means every parser handled it
identically. More than one is a fault line, and the page names who is on which
side.

```
   unknown_directive            2 camps   parsed: 9  |  error: 3
   yaml_2_0_directive           2 camps   error: 7  |  parsed: 5
   yes_no                       1 camp    parsed: 12
```

Nine parsers, including both reference parsers, accept a `%UNKNOWNDIRECTIVE` and
carry on. Psych, PyYAML's `CSafeLoader` and go-yaml refuse the document — the
first two being the same libyaml underneath, as usual.

`%YAML 2.0` splits the field almost evenly, and splits it the other way. Seven
libraries reject the document:

| parser | message |
|---|---|
| Psych (libyaml) | `found incompatible YAML document` |
| Psych (libfyaml) | `could not parse YAML at line 0 column 0` |
| PyYAML (pure) | `found incompatible YAML document (version 1.* is required)` |
| PyYAML (CSafeLoader) | `found incompatible YAML document` |
| js-yaml | `unacceptable YAML version of the document (2:1)` |
| go-yaml v3 | `found incompatible YAML document` |
| SnakeYAML Engine | `Version{major=2, minor=0}` |

rapidyaml, saphyr and YAMLStar parse it as an ordinary document, and so do both
reference parsers — which here is a fact about the reference parsers rather than
a verdict on the other seven. The spec's version rule is prose, not grammar:
§6.8.1 says a document with a higher *major* version should be rejected and a
higher *minor* version should warn, but the production it generates from is

```
ns-yaml-version ::= ns-dec-digit+ '.' ns-dec-digit+
```

which `2.0` satisfies as readily as `1.2`. The reference parsers are generated
from those productions, so they have nothing to reject with. This is the one
place in this harness where the reference rows are *not* the more spec-faithful
answer, and it is a useful reminder of what they actually are: an executable
copy of the grammar, not of the specification.

So the seven rejecting parsers are following the spec here and the five
accepting ones are not — the reverse of the usual reading. What the case is
worth keeping for is that the split exists at all, and that it does not line up
with any of the groupings the scored reports produce. Both Psych builds reject,
unlike `yes_no` and `unknown_directive` where they land in different camps; and
rapidyaml, saphyr and YAMLStar accept, having implemented the grammar and not
the paragraph. The suite states no expectation for `%YAML 2.0`, so none of this
appears anywhere in the scored tables.

The value run splits separately from the event run, which is where the schema
differences show up. `yes: no` parses to the identical event stream in all
twelve parsers and then resolves two different ways: `{"yes": "no"}` in seven of
them, and `{"true": false}` in Psych-on-libyaml and both PyYAMLs, which still
read YAML 1.1 booleans.

Psych on libfyaml lands in the *first* camp — same Ruby, same psych gem, same
`Psych::ScalarScanner`, different answer. Which is the kind of thing a custom
case is for: the suite has no `yes: no` document to state an expectation about,
so nothing in the scored reports would have surfaced it.

## Adding a parser

Adding a tenth parser is two steps, though the second of them — the emitter —
is where the work is:

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
| `YAML_CUSTOM_DIR` | `data/custom_cases` | where the local corpus lives |

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
