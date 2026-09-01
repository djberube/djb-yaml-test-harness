# js-yaml, the de facto YAML parser for Node.
#
# Version 5 exposes a real event API (`parseEvents`), which is why the emitter
# can translate events directly instead of reconstructing them from a tree.
FROM node:22-bookworm-slim

ARG JS_YAML_VERSION=5.4.1
RUN npm install -g --no-fund --no-audit "js-yaml@${JS_YAML_VERSION}"

# Globally installed packages are not on a script's default resolution path,
# so point NODE_PATH at them rather than making the emitter guess.
ENV NODE_PATH=/usr/local/lib/node_modules

RUN node -e "const y=require('js-yaml'); if (typeof y.parseEvents !== 'function') throw new Error('this js-yaml has no parseEvents; the emitter needs v5+')" \
 && node -e "process.stdout.write('js-yaml '+require('js-yaml/package.json').version+'\n')"

COPY emit.js /emit.js

WORKDIR /work
