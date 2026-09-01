FROM rust:1-bookworm AS build

WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src

# Cargo.lock is committed and --locked is enforced, so the crate versions
# compiled in are exactly the ones this harness attributes results to.
RUN cargo build --release --locked && cp target/release/emit /emit

FROM debian:bookworm-slim
COPY --from=build /emit /emit
ENTRYPOINT []
CMD ["/emit"]
