# Psych on its default backend: libyaml, the C library Ruby ships with.
#
# This is the stock configuration -- what `require 'yaml'` gives you on a
# normal Ruby install -- so it is the baseline the other Ruby image is
# compared against.
FROM ruby:3.4-bookworm

COPY emit.rb /emit.rb

# Fail at build time rather than reporting a bogus verdict later: if the
# expected backend is not what loaded, every result from this image would be
# mislabelled.
RUN ruby -ryaml -e 'raise "sanity check failed" unless YAML.load("a: 1") == {"a" => 1}' \
 && ruby -ryaml -e 'warn "psych #{Psych::VERSION} / libyaml #{Psych::LIBYAML_VERSION}"'

WORKDIR /work
