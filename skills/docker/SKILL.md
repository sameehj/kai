---
name: docker
description: Docker operations, debugging, and service triage.
version: "1.0"
tags: [docker, containers, compose, debugging]
requires:
  bins: [docker]
---

# Docker

```bash
docker ps
docker stats --no-stream
docker logs <container> --tail 100
docker inspect <container>
docker exec -it <container> /bin/sh
docker compose up -d
docker compose logs -f
```
