# syntax=docker/dockerfile:1

FROM ubuntu:22.04 AS builder
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git build-essential clang libclang-dev \
      pkg-config libssl-dev cmake python3 \
 && rm -rf /var/lib/apt/lists/*
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain 1.86.0 --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
WORKDIR /build
ARG NEARCORE_TAG=2.11.0
RUN git clone --depth 1 --branch ${NEARCORE_TAG} https://github.com/near/nearcore.git .
RUN make release

FROM ubuntu:22.04 AS runtime
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 998 neard \
 && useradd --system --gid neard --uid 998 --home-dir /home/neard \
            --shell /usr/sbin/nologin neard \
 && mkdir -p /home/neard/.near \
 && chown -R neard:neard /home/neard

COPY --from=builder /build/target/release/neard /usr/local/bin/neard

USER neard
WORKDIR /home/neard
EXPOSE 3030 24567
ENTRYPOINT ["/usr/local/bin/neard"]
CMD ["--home", "/home/neard/.near", "run"]
