package httpapi

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/yarik/squatter/backend/internal/store"
)

const maxSessionBytes = 1 << 20 // summary + rep metrics; never the series

func (a *api) putSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !isUUID(id) {
		writeError(w, http.StatusBadRequest, "id must be a UUID")
		return
	}
	var workout store.WorkoutSession
	r.Body = http.MaxBytesReader(w, r.Body, maxSessionBytes)
	if err := json.NewDecoder(r.Body).Decode(&workout); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if workout.Activity == "" || workout.Date.IsZero() {
		writeError(w, http.StatusBadRequest, "date and activity are required")
		return
	}
	if workout.Reps == nil {
		workout.Reps = json.RawMessage("[]")
	}
	workout.ID = id
	if err := a.deps.Store.UpsertWorkout(r.Context(), userFrom(r.Context()).ID, workout); err != nil {
		a.serverError(w, err, "workout upsert")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *api) listSessions(w http.ResponseWriter, r *http.Request) {
	var since *time.Time
	if raw := r.URL.Query().Get("since"); raw != "" {
		parsed, err := time.Parse(time.RFC3339, raw)
		if err != nil {
			writeError(w, http.StatusBadRequest, "since must be RFC3339")
			return
		}
		since = &parsed
	}
	sessions, err := a.deps.Store.ListWorkouts(r.Context(), userFrom(r.Context()).ID, since)
	if err != nil {
		a.serverError(w, err, "workout list")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": sessions})
}

func (a *api) deleteSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !isUUID(id) {
		writeError(w, http.StatusBadRequest, "id must be a UUID")
		return
	}
	if err := a.deps.Store.DeleteWorkout(r.Context(), userFrom(r.Context()).ID, id); err != nil {
		a.serverError(w, err, "workout delete")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// isUUID checks the 8-4-4-4-12 hex layout — enough to keep garbage out of
// the uuid cast; Postgres remains the final validator.
func isUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, char := range value {
		switch index {
		case 8, 13, 18, 23:
			if char != '-' {
				return false
			}
		default:
			isHex := (char >= '0' && char <= '9') ||
				(char >= 'a' && char <= 'f') || (char >= 'A' && char <= 'F')
			if !isHex {
				return false
			}
		}
	}
	return true
}
