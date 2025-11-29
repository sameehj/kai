package memory

// Embedding contains vector data used during recall.
type Embedding struct {
    Model string
    Data  []float32
}

// Embedder produces embeddings for arbitrary input.
type Embedder interface {
    Encode(input string) (Embedding, error)
}
