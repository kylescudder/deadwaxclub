FROM oven/bun:1.4.4@sha256:1d22548f177f4ff38e0c15baa3c2c46c6c2060ba2d1bc573bb4720b407548f1d AS build
WORKDIR /app/Backend
ENV HUSKY=0 CI=true
COPY Backend/package.json Backend/bun.lock ./
RUN bun install --frozen-lockfile
COPY Backend/src ./src
COPY Backend/scripts ./scripts
COPY Backend/db ./db
COPY Backend/drizzle ./drizzle
COPY Backend/deploy ./deploy
COPY Backend/tsconfig.json ./
RUN bunx --no-install tsc --noEmit && bun build src/index.ts --target=bun --outdir=dist --packages=external

FROM oven/bun:1.4.4@sha256:1d22548f177f4ff38e0c15baa3c2c46c6c2060ba2d1bc573bb4720b407548f1d
WORKDIR /app/Backend
ENV NODE_ENV=production HUSKY=0
COPY Backend/package.json Backend/bun.lock ./
RUN bun install --frozen-lockfile --production --ignore-scripts
COPY --from=build /app/Backend/dist ./dist
COPY --from=build /app/Backend/src ./src
COPY --from=build /app/Backend/scripts ./scripts
COPY --from=build /app/Backend/db ./db
COPY --from=build /app/Backend/drizzle ./drizzle
COPY --from=build /app/Backend/deploy ./deploy
ARG SOURCE_REVISION=development
ENV SOURCE_REVISION=${SOURCE_REVISION}
LABEL org.opencontainers.image.revision=${SOURCE_REVISION}
USER 1000:1000
EXPOSE 3147
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD ["bun", "-e", "const r = await fetch('http://127.0.0.1:3147/health/live', { signal: AbortSignal.timeout(3000) }); if (!r.ok || (await r.json()).ok !== true) process.exit(1)"]
CMD ["bun", "dist/index.js"]
