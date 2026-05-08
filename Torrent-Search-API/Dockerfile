FROM node:20-alpine
WORKDIR /app
COPY package.json package-lock.json* pnpm-lock.yaml* ./
ENV NODE_ENV=production
RUN npm install --production || npm install --production --legacy-peer-deps
COPY . .
EXPOSE 3001
CMD ["npm", "run", "start-server"]
