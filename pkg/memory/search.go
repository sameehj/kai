package memory

import "context"

// SearchEngine executes approximate nearest neighbor queries.
type SearchEngine interface {
    Query(ctx context.Context, embedding Embedding, limit int) ([]interface{}, error)
}
