FROM node:22-alpine
WORKDIR /app
COPY package.json server.mjs ./
RUN mkdir -p /data && chown -R node:node /app /data
USER node
ENV COORDKIT_RELAY_HOST=0.0.0.0 \
    COORDKIT_RELAY_PORT=8787 \
    COORDKIT_RELAY_DATA=/data
EXPOSE 8787
VOLUME ["/data"]
CMD ["node", "server.mjs"]
