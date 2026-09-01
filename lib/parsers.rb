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

  ALL = {
    'psych' => {
      label: 'Psych (libyaml)',
      lang: 'Ruby',
      note: 'Ruby stdlib YAML. libyaml under the hood.',
      dir: 'psych',
      tag: 'djb-yaml/psych:1',
      cmd: %w[ruby /emit.rb],
      version_cmd: %w[ruby -ryaml -e print("psych#{Psych::VERSION}/libyaml#{Psych::LIBYAML_VERSION}")]
    },

    'psych-fyaml' => {
      label: 'Psych (libfyaml)',
      lang: 'Ruby',
      note: 'Psych built --enable-libfyaml: the opt-in YAML 1.2 backend.',
      dir: 'psych_fyaml',
      tag: 'djb-yaml/psych-fyaml:1',
      cmd: %w[ruby /emit.rb],
      version_cmd: %w[ruby -ryaml -e print("psych#{Psych::VERSION}/libfyaml#{Psych.libfyaml_version}")]
    },

    'pyyaml' => {
      label: 'PyYAML (pure)',
      lang: 'Python',
      note: "PyYAML's pure-Python parser.",
      dir: 'pyyaml',
      tag: 'djb-yaml/pyyaml:1',
      cmd: %w[python3 /emit.py],
      version_cmd: ['python3', '-c', 'import yaml;print("pyyaml"+yaml.__version__,end="")']
    },

    'pyyaml-c' => {
      label: 'PyYAML (CSafeLoader)',
      lang: 'Python',
      note: "PyYAML's libyaml binding. Same C library as Psych.",
      dir: 'pyyaml',
      tag: 'djb-yaml/pyyaml:1',
      cmd: %w[python3 /emit.py --c],
      version_cmd: ['python3', '-c',
                    'import yaml;print("pyyaml"+yaml.__version__+"/libyaml"+".".join(map(str,yaml.__with_libyaml__ and __import__("_yaml").get_version() or ())),end="")']
    },

    'rapidyaml' => {
      label: 'rapidyaml',
      lang: 'C++',
      note: 'rapidyaml via its Python bindings. Aims at YAML 1.2.',
      dir: 'rapidyaml',
      tag: 'djb-yaml/rapidyaml:1',
      cmd: %w[python3 /emit.py],
      version_cmd: ['python3', '-c', 'import ryml;print("rapidyaml"+getattr(ryml,"__version__","?"),end="")']
    },

    'js-yaml' => {
      label: 'js-yaml',
      lang: 'JavaScript',
      note: 'The de facto YAML parser for Node. YAML 1.2 core schema.',
      dir: 'js_yaml',
      tag: 'djb-yaml/js-yaml:1',
      cmd: %w[node /emit.js],
      version_cmd: ['node', '-e', 'process.stdout.write("js-yaml"+require("js-yaml/package.json").version)']
    },

    'go-yaml' => {
      label: 'go-yaml v3',
      lang: 'Go',
      note: 'gopkg.in/yaml.v3, the parser behind most Go tooling.',
      dir: 'go_yaml',
      tag: 'djb-yaml/go-yaml:1',
      cmd: %w[/emit],
      version_cmd: %w[/emit --version]
    },

    'saphyr' => {
      label: 'saphyr',
      lang: 'Rust',
      note: 'Maintained fork of yaml-rust; targets YAML 1.2.',
      dir: 'saphyr',
      tag: 'djb-yaml/saphyr:1',
      cmd: %w[/emit],
      version_cmd: %w[/emit --version]
    },

    'snakeyaml' => {
      label: 'SnakeYAML Engine',
      lang: 'Java',
      note: 'The YAML 1.2 rewrite of SnakeYAML. Reference-grade 1.2 support.',
      dir: 'snakeyaml',
      tag: 'djb-yaml/snakeyaml:1',
      cmd: %w[java -cp /app/classes:/app/deps/* Emit],
      version_cmd: %w[java -cp /app/classes:/app/deps/* Emit --version]
    }
  }.freeze

  DEFAULT = ALL.keys.freeze

  def self.[](name) = ALL[name]

  def self.resolve(names)
    return DEFAULT if names.nil? || names.empty?

    names.each do |n|
      raise ArgumentError, "unknown parser #{n.inspect}; known: #{ALL.keys.join(', ')}" unless ALL.key?(n)
    end
    names
  end
end
