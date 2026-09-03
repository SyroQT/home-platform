FROM n8nio/n8n:2.38.3

USER root

RUN mkdir -p /usr/local/lib/custom-nodes && \
    cd /usr/local/lib/custom-nodes && \
    npm init -y && \
    npm install n8n-nodes-discord-trigger-new --ignore-scripts

ENV N8N_CUSTOM_EXTENSIONS=/usr/local/lib/custom-nodes

USER node
