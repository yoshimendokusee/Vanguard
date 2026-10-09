# Use the Docker Official Image hosted in ECR Public to avoid Docker Hub pull limits.
FROM public.ecr.aws/docker/library/node:22-bookworm-slim AS dependencies
WORKDIR /app
# The locked better-sqlite3 version compiles a native addon.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

FROM public.ecr.aws/docker/library/node:22-bookworm-slim AS development
WORKDIR /app
COPY --from=dependencies /app/node_modules ./node_modules
COPY . .
EXPOSE 3301
CMD ["npm", "run", "dev"]

FROM development AS build
RUN npm run build && npm prune --omit=dev --no-audit --no-fund

FROM public.ecr.aws/docker/library/node:22-bookworm-slim AS production
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY . .
COPY --from=build /app/dist ./dist
ENV PORT=3000 DB_PATH=/data/vanguard.db HOST=0.0.0.0 HUB_BIND_ADDRESS=127.0.0.1
VOLUME /data
EXPOSE 3000
CMD ["node", "server.js"]
