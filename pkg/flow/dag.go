package flow

// Node represents a single flow step within a DAG.
type Node struct {
    ID       string
    Depends  []string
}

// BuildDAG returns the nodes without validation.
func BuildDAG(steps []Node) []Node {
    return steps
}
