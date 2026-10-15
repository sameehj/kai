# Slow App Demo

This demo provides a reproducible latency bug for KAI to investigate.

## Start

```bash
cd demo/slow-app
docker compose up --build -d
```

## Warm and Load

```bash
./load.sh
```

## Bug

The API performs `KEYS *` against Redis on every request. As key count grows,
request latency rises significantly.

## Investigation Prompt

Use this prompt in KAI:

```text
The web service was ~50ms and is now ~500ms. Investigate and find root cause.
```
