package memory

import "context"

// PostgresStore is a stub for a Postgres backed memory implementation.
type PostgresStore struct{}

func (PostgresStore) StoreRun(ctx context.Context, data interface{}) error {
    return nil
}

func (PostgresStore) FindSimilar(ctx context.Context, query interface{}) ([]interface{}, error) {
    return nil, nil
}
