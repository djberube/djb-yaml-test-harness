# frozen_string_literal: true

# Paths and knobs shared by the rest of lib/.
module Config
  ROOT = File.expand_path('..', __dir__)

  # The yaml-test-suite checkout. Gitignored and cloned on demand by
  # lib/suite.rb -- vendoring 350 test directories into this repo would bury
  # the harness itself, and pinning a tag gets reproducibility without it.
  SUITE_DIR = File.join(ROOT, 'vendor', 'yaml-test-suite')
  SUITE_URL = 'https://github.com/yaml/yaml-test-suite.git'

  # The `data-*` tags hold one directory per case with in.yaml and test.event
  # already expanded, which is the layout this harness reads. `main` keeps the
  # cases as .tml source files instead and would need parsing first.
  SUITE_REF = ENV.fetch('YAML_SUITE_REF', 'data-2022-01-17')

  DOCKER_DIR = File.join(ROOT, 'docker')
  REPORT_DIR = File.join(ROOT, ENV.fetch('YAML_HARNESS_OUT', 'reports'))

  # Per-case timeout. A parser that hangs on a malformed document is itself a
  # finding, but it must not stall the run.
  CASE_TIMEOUT = Integer(ENV.fetch('YAML_HARNESS_TIMEOUT', '10'))

  # How many cases to hand a container per invocation. Container startup is
  # ~200ms and there are 350+ cases, so feeding them one at a time would mean
  # minutes of pure process spawn per parser. Each runner reads a batch of
  # documents on stdin and writes one result per case.
  BATCH_SIZE = Integer(ENV.fetch('YAML_HARNESS_BATCH', '64'))
end
