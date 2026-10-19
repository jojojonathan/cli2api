package trae

import (
	"encoding/json"

	"github.com/caigee-cmd/cli2api/internal/providers"
	"github.com/caigee-cmd/cli2api/internal/translate"
)

func normalizeReasoningLevel(raw string) string {
	return providers.NormalizeReasoningLevel(raw)
}

func requestedReasoningLevel(req translate.ChatRequest) string {
	if len(req.ReasoningEffort) > 0 {
		var value any
		if json.Unmarshal(req.ReasoningEffort, &value) == nil {
			switch typed := value.(type) {
			case string:
				if level := normalizeReasoningLevel(typed); level != "" {
					return level
				}
			case map[string]any:
				for _, key := range []string{"effort", "level", "type"} {
					if text, ok := typed[key].(string); ok {
						if level := normalizeReasoningLevel(text); level != "" {
							return level
						}
					}
				}
			}
		}
	}
	if req.EnableThinking != nil {
		if *req.EnableThinking {
			return "medium"
		}
		return "none"
	}
	if req.EnableReasoning != nil {
		if *req.EnableReasoning {
			return "medium"
		}
		return "none"
	}
	if req.IsReasoning != nil {
		if *req.IsReasoning {
			return "medium"
		}
		return "none"
	}
	return ""
}

func clampReasoningLevel(level string, caps providers.ModelCapabilities) string {
	resolved := providers.ResolveReasoningLevel(level, caps)
	if normalizeReasoningLevel(level) != "max" || resolved == "max" || len(caps.ReasoningOptions) == 0 {
		return resolved
	}
	// "max" is not a declared tier on this model (trae catalogs top out at
	// extra_high with a lower default, e.g. deepseek-v4.1-flash declares
	// light/high/extra_high with default high): pin it to the highest
	// declared tier instead of the catalog default so a max request still
	// means maximum thinking.
	for _, top := range []string{"xhigh", "high", "medium", "low", "none"} {
		for _, option := range caps.ReasoningOptions {
			if option == top {
				return option
			}
		}
	}
	return resolved
}

func applySoloChatFields(obj map[string]any, req translate.ChatRequest, maxMode bool, storedLevel string, caps providers.ModelCapabilities) {
	if obj == nil {
		return
	}
	for _, key := range []string{
		"enable_thinking", "enable_reasoning", "is_reasoning", "reasoning_effort",
		"reasoning_budget_tokens", "thinking", "context_length", "max_input_tokens",
	} {
		delete(obj, key)
	}
	if maxMode && caps.MaxMode {
		obj["is_max_mode"] = 1
	} else {
		delete(obj, "is_max_mode")
	}
	level := requestedReasoningLevel(req)
	if level == "" {
		level = storedLevel
	}
	level = clampReasoningLevel(level, caps)
	if level == "" {
		delete(obj, "reasoning_effort_level")
		return
	}
	obj["reasoning_effort_level"] = level
}

// resolvedReasoningLevel returns the clamped reasoning level actually sent
// upstream for the given request, or empty when no level is included.
func resolvedReasoningLevel(req translate.ChatRequest, storedLevel string, caps providers.ModelCapabilities) string {
	level := requestedReasoningLevel(req)
	if level == "" {
		level = storedLevel
	}
	return clampReasoningLevel(level, caps)
}
