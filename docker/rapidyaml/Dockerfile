# rapidyaml, through its Python bindings.
#
# The bindings are the practical way to drive ryml from a script; the parser
# underneath is the same C++ one, so the results are attributable to rapidyaml
# rather than to the binding layer.
FROM python:3.12-slim-bookworm

ARG RAPIDYAML_VERSION=0.15.2
RUN pip install --no-cache-dir "rapidyaml==${RAPIDYAML_VERSION}"

RUN python3 -c "import ryml; print('rapidyaml', getattr(ryml,'__version__','?'))"

COPY emit.py /emit.py

WORKDIR /work
