package agent

import (
	"encoding/json"
	"fmt"
)

func buildPrompt(req AnalysisRequest) string {
	contextJSON, _ := json.MarshalIndent(req.Context, "", "  ")

	basePrompt := fmt.Sprintf(`You are an expert SRE analyzing infrastructure issues.

Analysis Type: %s

Context from previous investigation steps:
%s

`, req.Type, string(contextJSON))

	if req.Prompt != "" {
		basePrompt += "\nAdditional Instructions:\n" + req.Prompt + "\n"
	}

	basePrompt += `
Analyze the data and respond with a JSON object in this exact format:
{
  "root_cause": "brief description of the root cause",
  "affected_component": "what component/service is affected",
  "recommended_action": "what to do next (investigate/fix/escalate/none)",
  "confidence": 0.85,
  "reasoning": "detailed explanation of your analysis"
}

CRITICAL: Respond with ONLY valid JSON. No markdown, no code blocks, no explanations outside the JSON.
`

	return basePrompt
}
