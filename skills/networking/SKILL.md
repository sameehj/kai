---
name: networking
description: Linux networking investigation and debugging.
version: "1.0"
tags: [networking, tcp, udp, dns, firewall]
---

# Networking

```bash
ss -tlnp
ss -ulnp
ss -s
ip -s link
ip route
dig <domain> +short
sudo iptables -L -n -v
sudo nft list ruleset
```
