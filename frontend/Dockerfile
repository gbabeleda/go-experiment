# syntax=docker/dockerfile:1

FROM ghcr.io/pnpm/pnpm:12.6.0 AS base

RUN pnpm runtime set node 24.21.0 -g && \
    chmod -R a+rX "$PNPM_HOME"

RUN groupadd --system --gid 999 appuser && \
useradd --system --gid 999 --uid 999 --create-home appuser

FROM base AS build

WORKDIR /app

COPY pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm fetch

COPY package.json ./
COPY frontend/ frontend/

RUN pnpm install --offline --frozen-lockfile --no-runtime

RUN pnpm --recursive run build

RUN pnpm --filter=nxt-app deploy --prod /prod/nxt-app


FROM base AS nxt-app
WORKDIR /app
COPY --from=build --chown=appuser:appuser /prod/nxt-app .
ENV pnpm_config_pm_on_fail=ignore \
    pnpm_config_verify_deps_before_run=false
USER appuser
EXPOSE 3002
CMD ["pnpm", "run", "start"]
