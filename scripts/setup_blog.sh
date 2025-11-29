#!/bin/bash
set -e

echo "📝 Setting up KAI Blog (GitHub Pages)"

# Create docs structure
mkdir -p docs/blog
mkdir -p docs/assets/{diagrams,screenshots}

# Create GitHub Pages config
cat > docs/_config.yml << 'EOF'
title: KAI Blog
description: Autonomous Infrastructure Debugging with eBPF + AI
theme: jekyll-theme-minimal
baseurl: /kai

plugins:
  - jekyll-feed
  - jekyll-seo-tag

markdown: kramdown
kramdown:
  input: GFM
  syntax_highlighter: rouge

collections:
  posts:
    output: true
    permalink: /blog/:year/:month/:day/:title/

defaults:
  - scope:
      path: ""
      type: "posts"
    values:
      layout: "post"
      author: "KAI Team"
EOF

# Create blog index
cat > docs/blog/index.md << 'EOF'
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
EOF

# Generate index from blog posts
cat > scripts/generate_blog_index.sh << 'EOF'
#!/bin/bash

echo "Generating blog index..."

# Find all blog posts
posts=$(find docs/blog -name "*.md" ! -name "index.md" | sort -r)

# Extract metadata and generate index
for post in $posts; do
    title=$(grep "^title:" "$post" | cut -d'"' -f2)
    date=$(grep "^date:" "$post" | cut -d' ' -f2)
    problem=$(grep "^problem:" "$post" | cut -d'"' -f2)

    echo "- [$title]($post) - $date"
    echo "  - Problem: $problem"
done
EOF

chmod +x scripts/generate_blog_index.sh

echo "✅ Blog setup complete!"
echo ""
echo "Next steps:"
echo "1. Enable GitHub Pages in repo settings"
echo "2. Set source to 'docs' folder"
echo "3. Your blog will be at: https://sameehj.github.io/kai/blog"
