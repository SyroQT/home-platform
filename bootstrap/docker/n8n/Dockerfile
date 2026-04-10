FROM n8nio/n8n:2.15.0

USER root
RUN cd /usr/local/lib/node_modules/n8n && \
    npm install n8n-nodes-discord-trigger-new
USER node
