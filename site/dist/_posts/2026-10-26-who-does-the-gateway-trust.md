---
layout: post
title: Who does Kai's gateway trust upstream?
description: Certificate validation, destination policy and redirects are separate checks before an API request leaves Kai.
category: Engineering notes
---

Kai's local gateway can inspect a model API request before forwarding it. That makes the gateway a sensitive place: it can handle prompts and API credentials. Before it sends them, two questions matter. **Is the destination one Kai intended to use? Is the TLS peer the genuine server for that destination?**

This applies only to traffic actually routed through the gateway. An agent connection that goes straight to a model API does not gain gateway checks merely because Kai is installed.

## What the source does today

The gateway has default upstream URLs for Anthropic, OpenAI and OpenRouter and forwards with libcurl. libcurl [verifies certificate chains and hostnames by default](https://curl.se/docs/sslcerts.html). Kai's source does not turn those checks off. It also does not currently set an explicit minimum TLS version or enforce a fixed destination list: environment variables can replace the default upstream base URLs. The gateway is a manual opt-in path, and this source review is not a live certificate test.

Those facts support a narrow statement: the current forwarding path **inherits libcurl's default TLS verification** for its configured URL. They do not establish that Kai has validated every redirect, override or deployment setting we might encounter.

## The invariant we want

For a first release, a fixed set of HTTPS upstreams is simpler to audit than editable or signed profiles. Kai should reject a URL outside that set before forwarding sensitive request data, verify the certificate chain and hostname, and stop on a TLS error. Redirects need an explicit decision too: either reject them or validate the new destination before any sensitive data is resent. There should be no retry with certificate verification disabled.

Using the system trust store is a deliberate choice. It trusts certificate authorities installed by the user or their organization; it is not certificate pinning. A valid certificate also does not make an arbitrary new hostname an approved destination. Destination policy and TLS authentication must both pass.

## How we would test it

Use a controlled local test server and separate cases for a trusted certificate with the **wrong hostname**, a trusted but **expired** certificate, and an **untrusted chain**. If all three fixtures are merely untrusted, the tests may exercise only one failure path. Add an allowed endpoint that redirects to an unapproved host, a non-HTTPS override, and a request that bypasses the gateway entirely. For each, record whether any request body or credential was sent and what error Kai reported.

Gateway TLS hardening is essential engineering work, not a novel security feature. The test results—not a green setting or a successful ordinary request—will tell us which guarantees Kai actually provides.
