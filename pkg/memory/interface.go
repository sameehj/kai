package memory

import "context"

type MemoryStore interface {
    StoreRun(ctx context.Context, data interface{}) error
    FindSimilar(ctx context.Context, query interface{}) ([]interface{}, error)
}
