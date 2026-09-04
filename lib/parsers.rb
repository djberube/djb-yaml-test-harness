# frozen_string_literal: true

# The parsers under test.
#
# Each entry names a docker context under docker/, the tag its image gets, and
# the command that runs the emitter inside it. Every emitter speaks the same
# protocol (see PROTOCOL below), so the comparison logic does not care which
# language produced a stream.
#
# `version_cmd` prints the parser's own version string, which goes into the
# report header -- a matrix without it is not reproducible.
#
# `value: true` marks an emitter that also supports `--json`, which makes it
# print the *loaded value* as JSON rather than the event stream. Those parsers
# can be scored on the suite's `json:` expectations as well as its `tree:`
# ones. Every real library does; the two reference parsers do not, because they
# parse and stop -- no schema, no loader, nothing to ask for a value. The value
# run skips them rather than reporting a zero for a mode they cannot answer.
#
# Each emitter projects its own language's loaded value onto JSON's type set,
# and each does it with the library's own resolver rather than a reimplemented
# schema -- the point is to measure what the library returns, not what this
# harness can reconstruct.
module Parsers
  # The wire protocol between the harness and a container.
  #
  # stdin:  one batch, as a repeating sequence of
  #             <id>\n<byte-length>\n<document bytes>
  #         terminated by a line reading `.`
  # stdout: for each input case, in order,
  #             === <id> <OK|ERR>
  #             <event lines, or the error message on one line>
  #
  # Byte lengths rather than delimiters because YAML documents contain every
  # delimiter one might pick, including lines of dots and dashes. Lengths are
  # unambiguous and let a document be copied through verbatim.
  PROTOCOL = <<~TXT
    stdin:  (<id>\\n<nbytes>\\n<bytes>)* then "."
    stdout: ("=== <id> <OK|ERR>\\n" <lines>)*
  TXT

  # The cross-language comparison. See COMBOS below for the Psych version
  # matrix, which is folded into ALL further down.
  BASE = {
    'psych' => {
      label: 'Psych (libyaml)',
      lang: 'Ruby',
      note: 'Ruby stdlib YAML. libyaml under the hood.',
      dir: 'psych',
      tag: 'djb-yaml/psych:3',
      cmd: %w[ruby /emit.rb],
      value: true,
      version_cmd: %w[ruby -ryaml -e print("psych#{Psych::VERSION}/libyaml#{Psych::LIBYAML_VERSION}")]
    },

    'psych-fyaml' => {
      label: 'Psych (libfyaml)',
      lang: 'Ruby',
      note: 'Psych built --enable-libfyaml: the opt-in YAML 1.2 backend.',
      dir: 'psych_fyaml',
      tag: 'djb-yaml/psych-fyaml:3',
      cmd: %w[ruby /emit.rb],
      value: true,
      version_cmd: %w[ruby -ryaml -e print("psych#{Psych::VERSION}/libfyaml#{Psych.libfyaml_version}")]
    },

    'pyyaml' => {
      label: 'PyYAML (pure)',
      lang: 'Python',
      note: "PyYAML's pure-Python parser.",
      dir: 'pyyaml',
      tag: 'djb-yaml/pyyaml:2',
      cmd: %w[python3 /emit.py],
      value: true,
      version_cmd: ['python3', '-c', 'import yaml;print("pyyaml"+yaml.__version__,end="")']
    },

    'pyyaml-c' => {
      label: 'PyYAML (CSafeLoader)',
      lang: 'Python',
      note: "PyYAML's libyaml binding. Same C library as Psych.",
      dir: 'pyyaml',
      tag: 'djb-yaml/pyyaml:2',
      cmd: %w[python3 /emit.py --c],
      value: true,
      version_cmd: ['python3', '-c',
                    'import yaml;print("pyyaml"+yaml.__version__+"/libyaml"+".".join(map(str,yaml.__with_libyaml__ and __import__("_yaml").get_version() or ())),end="")']
    },

    'rapidyaml' => {
      label: 'rapidyaml',
      lang: 'C++',
      note: 'rapidyaml via its Python bindings. Aims at YAML 1.2.',
      dir: 'rapidyaml',
      tag: 'djb-yaml/rapidyaml:2',
      cmd: %w[python3 /emit.py],
      value: true,
      version_cmd: ['python3', '-c', 'import ryml;print("rapidyaml"+getattr(ryml,"__version__","?"),end="")']
    },

    'js-yaml' => {
      label: 'js-yaml',
      lang: 'JavaScript',
      note: 'The de facto YAML parser for Node. YAML 1.2 core schema.',
      dir: 'js_yaml',
      tag: 'djb-yaml/js-yaml:2',
      cmd: %w[node /emit.js],
      value: true,
      version_cmd: ['node', '-e', 'process.stdout.write("js-yaml"+require("js-yaml/package.json").version)']
    },

    'go-yaml' => {
      label: 'go-yaml v3',
      lang: 'Go',
      note: 'gopkg.in/yaml.v3, the parser behind most Go tooling.',
      dir: 'go_yaml',
      tag: 'djb-yaml/go-yaml:2',
      cmd: %w[/emit],
      value: true,
      version_cmd: %w[/emit --version]
    },

    'saphyr' => {
      label: 'saphyr',
      lang: 'Rust',
      note: 'Maintained fork of yaml-rust; targets YAML 1.2.',
      dir: 'saphyr',
      tag: 'djb-yaml/saphyr:2',
      cmd: %w[/emit],
      value: true,
      version_cmd: %w[/emit --version]
    },

    'snakeyaml' => {
      label: 'SnakeYAML Engine',
      lang: 'Java',
      note: 'The YAML 1.2 rewrite of SnakeYAML. Reference-grade 1.2 support.',
      dir: 'snakeyaml',
      tag: 'djb-yaml/snakeyaml:2',
      cmd: %w[java -cp /app/classes:/app/deps/* Emit],
      value: true,
      version_cmd: %w[java -cp /app/classes:/app/deps/* Emit --version]
    },

    'yamlstar' => {
      label: 'YAMLStar',
      lang: 'Clojure',
      note: 'Pure-Clojure YAML 1.2 stack. Parser and loader are separate artifacts.',
      dir: 'yamlstar',
      tag: 'djb-yaml/yamlstar:1',
      cmd: ['java', '-cp', '/app/lib/*', 'clojure.main', '/app/emit.clj'],
      value: true,
      version_cmd: ['java', '-cp', '/app/lib/*', 'clojure.main', '/app/emit.clj', '--version']
    },

    # --- the reference parsers ------------------------------------------------
    #
    # These two are not libraries anyone ships. They are generated from the
    # YAML 1.2 spec grammar -- one function per BNF production -- which makes
    # them the closest executable thing to the spec itself, and slow enough
    # that nobody would parse a config file with one.
    #
    # They are here as the control rows. Every other row is a hand-written
    # approximation of the same grammar, so a case one of them fails and
    # a reference row passes is a deviation from the spec; a case the reference
    # rows fail too is a place the spec, the suite, or the generated grammar
    # disagree with each other. That distinction is not available from the
    # suite's expectations alone.
    #
    # Both are `value: false`. A reference parser is a parser and stops there:
    # it builds an event stream and has no schema, no tag resolution to native
    # types, and no loader. The value run skips them rather than scoring a
    # question they do not answer.

    'ref-js' => {
      label: 'reference (JS)',
      lang: 'JavaScript',
      note: 'YAML 1.2 reference parser, generated from the spec grammar.',
      dir: 'ref_js',
      tag: 'djb-yaml/ref-js:1',
      cmd: %w[node /emit.js],
      value: false,
      version_cmd: %w[node /version.js]
    },

    'ref-perl' => {
      label: 'reference (Perl)',
      lang: 'Perl',
      note: 'The same spec grammar generated into Perl. Pinned to one commit with ref-js.',
      dir: 'ref_perl',
      tag: 'djb-yaml/ref-perl:1',
      cmd: %w[perl /emit.pl],
      value: false,
      version_cmd: %w[perl /version.pl]
    }
  }.freeze

  # --- the Psych version matrix ----------------------------------------------
  #
  # Psych's behaviour is the product of three separately-versioned things: the
  # Ruby it runs on, the psych gem, and the libyaml it links against. Varying
  # them one at a time is what makes a difference attributable -- a row that
  # differs from the baseline in exactly one component locates the change in
  # that component.
  #
  # The baseline is ruby 3.4 / psych 5.2.2 / libyaml 0.2.5, which is what the
  # `psych` entry above already runs, so it is not repeated here.
  #
  # These are representative, not exhaustive. A full cross-product would be
  # ~100 images and most of the cells are uninteresting or do not build: psych
  # 4 and 5 need Ruby 3.x, and Ruby 2.7/3.0 have no bookworm base image (hence
  # :suite). Every combination listed here is one that actually builds and
  # whose build asserts the versions it ended up with.
  #
  # Regenerate the Dockerfiles after editing this table:
  #
  #   ruby docker/psych_matrix/generate.rb
  #
  COMBOS = {
    # Varying psych alone, against the baseline Ruby and libyaml. This is the
    # axis most people mean by "which Psych"; it is also the axis where the
    # YAML 1.1 to 1.2 schema work landed.
    'psych-3.3.2' => {
      slug: 'psych3',
      ruby: '3.4', psych: '3.3.2', libyaml: '0.2.5',
      note: 'Psych 3, the pre-4 parser. Ruby <= 3.0 shipped this line.'
    },
    'psych-4.0.4' => {
      slug: 'psych4',
      ruby: '3.4', psych: '4.0.4', libyaml: '0.2.5',
      note: 'Psych 4, where load became safe_load by default. Ruby 3.1 shipped it.'
    },
    'psych-5.0.1' => {
      slug: 'psych5-0',
      ruby: '3.4', psych: '5.0.1', libyaml: '0.2.5',
      note: 'First of the psych 5 line. Ruby 3.2 shipped it.'
    },
    'psych-5.1.2' => {
      slug: 'psych5-1',
      ruby: '3.4', psych: '5.1.2', libyaml: '0.2.5',
      note: 'Psych 5.1, as shipped with Ruby 3.3.'
    },

    # Varying libyaml alone, against the baseline Ruby and psych. Nobody ships
    # these pairings; that is the point. Holding psych fixed is what separates
    # a C parser change from a Ruby-side one.
    'libyaml-0.2.1' => {
      slug: 'libyaml0-2-1',
      ruby: '3.4', psych: '5.2.2', libyaml: '0.2.1',
      note: 'Baseline psych against libyaml 0.2.1, four patch releases back.'
    },
    'libyaml-0.2.2' => {
      slug: 'libyaml0-2-2',
      ruby: '3.4', psych: '5.2.2', libyaml: '0.2.2',
      note: 'Baseline psych against the libyaml Ruby 2.7 and 3.0 shipped with.'
    },
    'libyaml-0.2.6' => {
      slug: 'libyaml0-2-6',
      ruby: '3.4', psych: '5.2.2', libyaml: '0.2.6-rc.1',
      note: 'Baseline psych against the unreleased libyaml 0.2.6 candidate.'
    },

    # Varying Ruby alone, holding psych and libyaml at the baseline. Any
    # difference here is the interpreter, not the parser -- which is the
    # comparison that says whether "it broke when I upgraded Ruby" was really
    # about Ruby at all.
    'ruby-3.1' => {
      slug: 'ruby3-1',
      ruby: '3.1', psych: '5.2.2', libyaml: '0.2.5',
      note: 'Baseline psych and libyaml on Ruby 3.1.'
    },
    'ruby-3.5' => {
      slug: 'ruby3-5',
      ruby: '3.5-rc', psych: '5.2.2', libyaml: '0.2.5',
      note: 'Baseline psych and libyaml on the Ruby 3.5 release candidate.'
    }
  }.freeze

  # COMBOS entries become parsers too, sharing the emitter and the protocol
  # with every other row. Built from docker/psych_matrix with -f because the
  # combos share one emit.rb and a build context cannot reach above itself.
  MATRIX = COMBOS.to_h do |id, c|
    [id, {
      label: "Psych #{c[:psych]} (ly#{c[:libyaml]}, rb#{c[:ruby]})",
      lang: 'Ruby',
      note: c[:note],
      dir: 'psych_matrix',
      dockerfile: "Dockerfile.#{c[:slug]}",
      tag: "djb-yaml/psych-matrix-#{c[:slug]}:3",
      cmd: %w[ruby /emit.rb],
      value: true,
      version_cmd: %w[ruby -ryaml -e print("psych#{Psych::VERSION}/libyaml#{Psych::LIBYAML_VERSION}/ruby#{RUBY_VERSION}")]
    }]
  end.freeze

  # The matrix rows are parsers like any other, but they are not in DEFAULT:
  # a bare `bin/conform` run should stay the cross-language comparison it was,
  # not nine Psych builds plus everyone else. Ask for them by id, or with the
  # --matrix-only shorthand.
  ALL = BASE.merge(MATRIX).freeze

  # Everything except the version matrix. Adding a combo to COMBOS therefore
  # does not silently change what the headline table measures.
  DEFAULT = BASE.keys.freeze

  # The baseline the matrix varies from is `psych` itself, so it is included:
  # rows are only interpretable against it.
  MATRIX_SET = (['psych'] + MATRIX.keys).freeze

  def self.[](name) = ALL[name]

  def self.resolve(names)
    return DEFAULT if names.nil? || names.empty?

    names.each do |n|
      raise ArgumentError, "unknown parser #{n.inspect}; known: #{ALL.keys.join(', ')}" unless ALL.key?(n)
    end
    names
  end
end
