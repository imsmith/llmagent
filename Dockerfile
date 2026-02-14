# Build stage
FROM elixir:1.16-alpine AS build

RUN apk add --no-cache git build-base

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config/ config/
RUN mix deps.get --only prod && mix deps.compile

COPY lib/ lib/
RUN mix compile && mix release llmagent

# Runtime stage
FROM alpine:3.19

RUN apk add --no-cache \
    bash \
    openssl \
    ncurses-libs \
    libstdc++ \
    wireguard-tools \
    openssh-client \
    gnupg

RUN addgroup -S llmagent && adduser -S llmagent -G llmagent

WORKDIR /app
COPY --from=build /app/_build/prod/rel/llmagent ./
RUN chown -R llmagent:llmagent /app

USER llmagent

ENV LLMAGENT_MODEL=gpt-4
ENV LLMAGENT_API_HOST=http://localhost:4000
ENV LLMAGENT_ROLE=default

LABEL org.opencontainers.image.source=https://github.com/imsmith/llmagent
LABEL org.opencontainers.image.licenses=AGPL-3.0

CMD ["bin/llmagent", "start"]
