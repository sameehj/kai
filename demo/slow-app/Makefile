.PHONY: up down inject clean

up:
	docker compose -f docker-compose.yaml up -d
	@echo "Demo running. Access at http://localhost:8080"

inject: up
	bash inject-problems.sh

down:
	docker compose -f docker-compose.yaml down

clean: down
	sudo iptables -D OUTPUT -p tcp --dport 5432 -m statistic --mode random --probability 0.05 -j DROP 2>/dev/null || true
