# PyYAML, both backends in one image.
#
# The pure-Python parser and the libyaml binding ship in the same package and
# differ only in which Loader class you ask for, so building them separately
# would mean compiling libyaml twice to compare two code paths in one library.
# lib/parsers.rb points two entries at this image and passes --c for the
# binding.
FROM python:3.12-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential libyaml-dev \
    && rm -rf /var/lib/apt/lists/*

# --no-binary forces a source build so the libyaml extension is compiled
# against the libyaml installed above; the manylinux wheel bundles its own and
# would make the reported libyaml version a fiction.
ARG PYYAML_VERSION=6.0.2
RUN pip install --no-cache-dir --no-binary=:all: "PyYAML==${PYYAML_VERSION}"

# Prove the C extension actually loaded. Without this the image would silently
# fall back to the pure-Python parser and report both rows as identical.
RUN python3 -c "import yaml; assert yaml.__with_libyaml__, 'libyaml binding missing'" \
 && python3 -c "import yaml; print('pyyaml', yaml.__version__)"

COPY emit.py /emit.py

WORKDIR /work
