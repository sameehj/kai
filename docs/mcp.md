# MCP Usage

## Start MCP Server (stdio)

```bash
./bin/kai-mcp --config ~/.kai/config.yaml
```

## Initialize

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
```

## List Tools

```json
{"jsonrpc":"2.0","id":2,"method":"kai.tools.list","params":{}}
```

## Get Tool

```json
{"jsonrpc":"2.0","id":3,"method":"kai.tools.get","params":{"name":"docker-debugger"}}
```

## Create Tool

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "kai.tools.create",
  "params": {
    "name": "example-tool",
    "content": "# Example Tool\n\nDescribe the tool here.\n"
  }
}
```

## Exec Command

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "kai.exec",
  "params": {
    "cmd": "uname",
    "args": ["-a"]
  }
}
```

## System Info

```json
{"jsonrpc":"2.0","id":6,"method":"kai.system.info","params":{}}
```
