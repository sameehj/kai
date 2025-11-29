---
layout: default
title: KAI Blog
---

# KAI Blog

Real-world investigations powered by Kernel Agentic Intelligence (eBPF + AI flows).

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

KAI (Kernel Agentic Intelligence) is an autonomous debugging agent that orchestrates CO-RE eBPF sensors, system telemetry, and Claude AI to surface root causes in seconds.

[GitHub](https://github.com/yourusername/kai) | [Documentation](/kai/) | [Install](https://github.com/yourusername/kai#quick-start)
