package gateway

import (
	"net/http"
	"strings"
	"sync/atomic"

	"github.com/caigee-cmd/cli2api/internal/auth"
	"github.com/caigee-cmd/cli2api/internal/executor"
	applogs "github.com/caigee-cmd/cli2api/internal/logs"
)

// CatalogQuery loads the public /v1/models display catalog. Gateway must not
// import store or the runtime manager; app injects the catalog fetch path.
type CatalogQuery func(refresh bool, accountID string) ([]map[string]any, error)

type Handler struct {
	Executor          executor.ChatExecutor
	Pool              *executor.Pool
	Recorder          *applogs.RequestRecorder
	ModelContexts     executor.ModelContextStore
	Catalogs          executor.CatalogPreparer
	Logs              executor.RequestStarter
	CrossProviderPool *atomic.Bool
	Models            CatalogQuery
	RequestedAccount  func(*http.Request) string
	FilterModels      func(*http.Request, []map[string]any) []map[string]any
	DecorateModels    func(*http.Request, []map[string]any) []map[string]any
}

func (h *Handler) requestIdentity(r *http.Request) auth.Identity {
	if r == nil {
		return auth.Identity{Kind: auth.KindNone}
	}
	identity, ok := auth.IdentityFrom(r.Context())
	if ok {
		return identity
	}
	return auth.Identity{Kind: auth.KindNone}
}

func (h *Handler) requestedAccount(r *http.Request) string {
	if h != nil && h.RequestedAccount != nil {
		return h.RequestedAccount(r)
	}
	return ""
}

// ResolveSessionHeader returns the session identifier a client wants account
// affinity keyed on. X-CLI2API-Session wins when set; otherwise clients that
// only send x-session-id (stable per session, unique per sub-agent, e.g.
// zcode) fall back to it so parallel sub-agents of the same type no longer
// collapse onto one pooled account via the shared content fingerprint.
func ResolveSessionHeader(r *http.Request) string {
	if r == nil {
		return ""
	}
	if value := strings.TrimSpace(r.Header.Get("X-CLI2API-Session")); value != "" {
		return value
	}
	return strings.TrimSpace(r.Header.Get("x-session-id"))
}

func (h *Handler) crossProviderPoolOn() bool {
	return h != nil && h.CrossProviderPool != nil && h.CrossProviderPool.Load()
}
