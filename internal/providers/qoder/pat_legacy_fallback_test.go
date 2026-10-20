package qoder

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/caigee-cmd/cli2api/internal/accounts"
)

// stubPATStore hands out either a fixed PAT payload or the store's
// not-found error, standing in for accounts with and without a
// credential-payload row (PAT accounts vs legacy blob accounts).
type stubPATStore struct {
	found  bool
	format string
}

func (s stubPATStore) LoadCredentialPayload(ctx context.Context, accountID string) (string, []byte, error) {
	if !s.found {
		return "", nil, accounts.ErrAccountNotFound
	}
	return s.format, []byte("fake-pat-secret-0123456789abcdef"), nil
}

func (s stubPATStore) SaveCredentialPayload(ctx context.Context, accountID, format string, payload []byte) error {
	return nil
}

// Legacy accounts predate the credential-payload table: the store answers
// ErrAccountNotFound, which must surface as ErrPATRequired so every caller
// falls back to the worker path instead of failing outright.
func TestBridgeMapsMissingPayloadRowToPATRequired(t *testing.T) {
	c := NewClient()
	c.SetPATStore(stubPATStore{found: false}, nil)
	_, err := c.Bridge(context.Background(), "acc-legacy")
	if !errors.Is(err, ErrPATRequired) {
		t.Fatalf("Bridge err = %v, want ErrPATRequired", err)
	}
}

func TestModelsFallsBackToWorkerWhenPayloadRowMissing(t *testing.T) {
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/admin/models" {
			t.Errorf("unexpected path %s", r.URL.Path)
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]any{{"id": "glm-5.2", "native_model": "glm-5"}},
		})
	}))
	defer worker.Close()

	c := NewClient()
	c.SetPATStore(stubPATStore{found: false}, nil)
	c.Bind(func(id string) (string, bool) { return worker.URL, true }, func() string { return "" })
	models, err := c.Models(context.Background(), "acc-legacy")
	if err != nil {
		t.Fatalf("Models err = %v", err)
	}
	if len(models) != 1 || models[0].NativeModel != "glm-5" {
		t.Fatalf("models = %+v", models)
	}
}

// PAT-backed accounts probe via the Bridge and report ready with the
// gateway identity, so refreshInProcess persists a ready status for them.
func TestProbeUsesBridgeForPATAccount(t *testing.T) {
	const pat = "fake-pat-secret-0123456789abcdef"
	c := NewClient()
	c.SetPATStore(stubPATStore{found: true, format: PATCredentialFormat}, nil)
	// Pre-populate the bridge cache with a far-future session so
	// EnsureFreshSession is a no-op and no network is touched.
	b := newTestBridge(t, pat)
	c.bridgesMu.Lock()
	c.bridges = map[string]*cachedBridge{
		"acc-pat": {bridge: b, patSig: patSignature(pat, "global")},
	}
	c.bridgesMu.Unlock()

	health, err := c.Probe(context.Background(), "acc-pat")
	if err != nil {
		t.Fatalf("Probe err = %v", err)
	}
	if !health.Ready {
		t.Fatalf("health = %+v, want ready", health)
	}
	if health.UID != "test-uid-12345" {
		t.Fatalf("health.UID = %q", health.UID)
	}
}

// Legacy accounts fall through the bridge probe to the worker /health
// endpoint, keeping the pre-PAT probe behavior intact.
func TestProbeFallsBackToWorkerForLegacyAccount(t *testing.T) {
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" {
			t.Errorf("unexpected path %s", r.URL.Path)
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok": true, "ready": true, "hot": true, "uid": "u1",
		})
	}))
	defer worker.Close()

	c := NewClient()
	c.SetPATStore(stubPATStore{found: false}, nil)
	c.Bind(func(id string) (string, bool) { return worker.URL, true }, func() string { return "" })
	health, err := c.Probe(context.Background(), "acc-legacy")
	if err != nil {
		t.Fatalf("Probe err = %v", err)
	}
	if !health.Ready || health.UID != "u1" {
		t.Fatalf("health = %+v", health)
	}
}
