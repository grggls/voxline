FROM node:24-alpine AS builder
WORKDIR /app
COPY package.json tsconfig.base.json ./
COPY packages/shared/package.json packages/shared/
COPY gateway/package.json gateway/
RUN npm install
COPY packages/shared/ packages/shared/
COPY gateway/ gateway/
RUN npm run build -w packages/shared && npm run build -w gateway

FROM node:24-alpine
WORKDIR /app
COPY --from=builder /app/package.json ./
COPY --from=builder /app/packages/shared/package.json packages/shared/
COPY --from=builder /app/packages/shared/dist packages/shared/dist
COPY --from=builder /app/gateway/package.json gateway/
COPY --from=builder /app/gateway/dist gateway/dist
COPY --from=builder /app/node_modules node_modules
EXPOSE 3000
CMD ["node", "gateway/dist/index.js"]
