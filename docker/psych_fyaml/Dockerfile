# Psych built against libfyaml: the opt-in backend that follows YAML 1.2 where
# the default libyaml build follows 1.1.
#
# Two things make this awkward enough to need an image rather than a gem
# install on the host:
#
#  1. Psych's libfyaml backend is opt-in (`--enable-libfyaml`) and needs
#     libfyaml >= 0.9, newer than what the distros package. So libfyaml is
#     built here from a pinned release tag.
#
#  2. The *published* psych 5.5.0 gem cannot build this backend at all. Its
#     gemspec carries a hardcoded `s.files` list that was never updated with
#     ext/psych/psych_parser_fy.c and psych_emitter_fy.c, so the gem ships
#     psych_parser.c with its whole body behind `#ifndef PSYCH_USE_LIBFYAML`
#     and nothing that defines the replacement. It compiles, then dies at
#     require time with "undefined symbol: Init_psych_parser". So psych is
#     built from a git checkout, where those files exist.

FROM ruby:3.4-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential autoconf automake libtool pkg-config git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG LIBFYAML_VERSION=0.9
RUN git clone --depth 1 --branch v${LIBFYAML_VERSION} \
      https://github.com/pantoniou/libfyaml.git /tmp/libfyaml \
    && cd /tmp/libfyaml \
    && ./bootstrap.sh \
    && ./configure --prefix=/usr/local \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig \
    && rm -rf /tmp/libfyaml

# Pinned to a commit, not a branch, so the image is reproducible -- this
# harness attributes results to a specific parser build, and a moving master
# would silently change them. This SHA is the v5.5.0 release commit.
ARG PSYCH_REF=9b12bb3fb679c2bc2399ffec0bed15b58ce839e8
RUN git clone https://github.com/ruby/psych.git /tmp/psych \
    && cd /tmp/psych \
    && git checkout ${PSYCH_REF} \
    && git rev-parse HEAD > /psych-commit \
    && cd ext/psych \
    && ruby extconf.rb --enable-libfyaml \
    && make -j"$(nproc)" \
    && make install

# The build above installs psych.so over Ruby's bundled copy, but the *default*
# psych gem's .rb files stay on the load path -- and this branch's
# scalar_scanner.rb keys its YAML 1.1 vs 1.2 boolean set off Psych::BACKEND, so
# the Ruby side has to come from the same checkout as the extension.
RUN cp -r /tmp/psych/lib/psych.rb /tmp/psych/lib/psych \
      "$(ruby -e 'print RbConfig::CONFIG["rubylibdir"]')/"

# Fail at build time rather than silently running the libyaml backend:
# Psych::BACKEND is set by the compiled extension, so it proves which parser
# actually loaded. Without this check every result from this image would be
# attributed to libfyaml when it came from libyaml.
RUN ruby -ryaml -e 'abort "got the #{Psych::BACKEND} backend, not libfyaml" unless Psych::BACKEND == "libfyaml"' \
    && ruby -ryaml -e 'warn "psych #{Psych::VERSION} (#{File.read("/psych-commit").strip[0,12]}) / libfyaml #{Psych.libfyaml_version}"' \
    && ruby -ryaml -e 'raise "sanity check failed" unless YAML.load("a: 1") == {"a" => 1}'

COPY emit.rb /emit.rb

WORKDIR /work
