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
