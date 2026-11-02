---
layout: post
title: Shipping an open-source macOS security tool
description: The code is public; the signed system extension still needs Apple's entitlements, profiles and notarization.
category: Kai field notes
date: 2026-11-02 20:50:00 +0200
---

Publishing Kai's source was the easy part of making it installable on another Mac. The app contains a network system extension. A public build needs the right Apple entitlement, a Developer ID identity, provisioning profiles, notarization and a package that Gatekeeper accepts. Open source does not remove those distribution requirements.

Our release script builds the app and extension, embeds their profiles, signs them, notarizes the app, staples the ticket, then builds and signs a universal installer package. It checks the result instead of trusting a successful exit code. In particular, `notarytool` can exit successfully while the submission's status is not Accepted, so the script checks the status text before continuing. The [release script](https://github.com/sameehj/kai/blob/master/scripts/release/build-preview-pkg.sh) and [signing checks](https://github.com/sameehj/kai/blob/master/scripts/release/sign-app.sh) are public.

Several details cost more time than the command list suggests. Development signing and Developer ID distribution use different forms of the Network Extension content-filter entitlement. The app and its extension each need a matching profile. An unsigned intermediate build can lose the Apple team prefix in the extension's Mach service name, so the release build inserts it and checks the packaged value. A macOS system extension also will not be replaced just because the surrounding app changed: its version must advance. Preview 2's [known issue](https://github.com/sameehj/kai/blob/master/docs/release/0.2.0-preview.2.md) describes what that meant for Macs that already ran a development build.

The Files wall adds another gate. Kai's Endpoint Security extension has been developed and tested privately, but its distribution entitlement was still pending for this preview. The release script explicitly refuses to package it. That is why Preview 2 says **Files protection is not included**, even though related source exists in the repository.

We chose to publish the boundary along with the artifact: a signed, notarized Preview 2 package for macOS 13 and later, agent hooks that check supported actions, and an Internet wall that watches rather than blocks. A reader can inspect the code; a user can verify the downloaded package with the checksum and `spctl` steps in the [README](https://github.com/sameehj/kai#verify-the-download). Neither step should be confused with proof that every attack path is covered.

*Next in the series: [Releasing when CI won't run]({{ '/blog/releasing-when-ci-wont-run/' | relative_url }}).*
