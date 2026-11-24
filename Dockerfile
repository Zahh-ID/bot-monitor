FROM node:22-bookworm-slim
WORKDIR /app
COPY package*.json ./
RUN npm ci --ignore-scripts
COPY . .
RUN npm run build
EXPOSE 3200
CMD ["npm","start"]
