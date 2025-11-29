package flow

// ConditionEvaluator determines whether a step should run.
type ConditionEvaluator interface {
    Evaluate(stepID string, expression string, ctx map[string]interface{}) bool
}

type AlwaysEvaluator struct{}

func (AlwaysEvaluator) Evaluate(stepID string, expression string, ctx map[string]interface{}) bool {
    return true
}
