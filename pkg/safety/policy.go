package safety

// Policy describes a safety policy rule set.
type Policy struct {
    ID      string
    Version string
}

// Engine evaluates policy decisions.
type Engine interface {
    Evaluate(policy Policy, subject string) (bool, error)
}
