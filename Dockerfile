# Build the `lpa` daemon in a pinned Rust image, run it from a slim base.
FROM rust:1.96-slim AS builder
WORKDIR /app
RUN apt-get update \
    && apt-get install -y --no-install-recommends protobuf-compiler pkg-config \
    && rm -rf /var/lib/apt/lists/*
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
COPY proto ./proto
RUN cargo build --release --bin lpa

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --uid 10001 lpa
COPY --from=builder /app/target/release/lpa /usr/local/bin/lpa
USER lpa
ENTRYPOINT ["lpa"]
CMD ["serve"]
