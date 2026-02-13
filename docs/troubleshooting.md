# Troubleshooting

## Gateway won't start
- Ensure port 18789 is free
- Try a different port and update your client

## No response in chat
- Verify the gateway is running
- Check that `kai chat` connects to `ws://127.0.0.1:18789/ws`

## Skills not found
- Ensure skills are in `skills/<name>/SKILL.md`
- Run `kai init` to create a workspace skeleton
