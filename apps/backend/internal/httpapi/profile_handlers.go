package httpapi

import (
	"encoding/json"
	"io"
	"net/http"

	"github.com/yarik/squatter/backend/internal/store"
)

const maxDocumentBytes = 256 << 10 // profile documents are a few KB

// getDocument returns the stored client document verbatim (the server never
// looks inside); 404 when the user has none yet.
func (a *api) getDocument(kind store.DocumentKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		payload, _, err := a.deps.Store.Document(r.Context(), kind, userFrom(r.Context()).ID)
		if err != nil {
			a.serverError(w, err, "document load")
			return
		}
		if payload == nil {
			writeError(w, http.StatusNotFound, "no document")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(payload)
	}
}

func (a *api) putDocument(kind store.DocumentKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxDocumentBytes))
		if err != nil {
			writeError(w, http.StatusRequestEntityTooLarge, "document too large")
			return
		}
		if !json.Valid(body) {
			writeError(w, http.StatusBadRequest, "invalid JSON")
			return
		}
		if err := a.deps.Store.SetDocument(
			r.Context(), kind, userFrom(r.Context()).ID, body,
		); err != nil {
			a.serverError(w, err, "document save")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}
