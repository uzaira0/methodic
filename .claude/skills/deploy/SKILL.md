---
name: deploy
description: Build and deploy Chronicle backend Docker container
disable-model-invocation: true
---

# Deploy Chronicle Backend

1. Build the backend image:
   ```bash
   cd /opt/chronicle && docker build -f docker/Dockerfile.backend -t chronicle-backend:latest .
   ```

2. Deploy with docker compose (always use `-p chronicle`):
   ```bash
   cd /opt/chronicle/docker && docker compose -f docker-compose.traefik.yml -p chronicle up -d chronicle-backend
   ```

3. Verify deployment:
   ```bash
   cd /opt/chronicle/docker && docker compose -f docker-compose.traefik.yml -p chronicle ps
   ```

4. Show container status to the user. If any container is unhealthy, show its logs:
   ```bash
   docker logs --tail 20 chronicle-chronicle-backend-1
   ```
