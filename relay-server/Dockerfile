FROM rust:1.85-slim AS builder

WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src/ src/

RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/station-relay-server /usr/local/bin/station-relay-server

EXPOSE 3000

ENV RUST_LOG=info

CMD ["station-relay-server"]
