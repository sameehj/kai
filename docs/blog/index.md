---
layout: default
title: KAI Blog
---

# KAI Blog

Real-world infrastructure debugging problems solved with eBPF + AI.

## Latest Posts

{% for post in site.posts %}
- [{{ post.title }}]({{ post.url }}) - {{ post.date | date: "%B %d, %Y" }}
  - **Problem:** {{ post.problem }}
  - **Solution:** {{ post.solution }}
{% endfor %}

## Topics

- [Performance](#performance)
- [Networking](#networking)
- [Security](#security)
- [eBPF](#ebpf)

---

## About KAI

KAI (Kubernetes AI Investigator) is an autonomous debugging agent that orchestrates the eBPF ecosystem (Cilium, Hubble, Tetragon, Parca) with Claude AI to solve production issues in seconds.

[GitHub](https://github.com/sameehj/kai) | [Documentation](/) | [Install](/#installation)
