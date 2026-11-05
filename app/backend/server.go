package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	appVersion    = "1.0.0"
	scriptVersion = "1.0.0"

	configSubfolder = "ugvm-backup"
	configFile      = "config.ini"
	statusFile      = "status.json"
	requestsFolder  = "requests"
	settingsFile    = "settings.json"
	scriptTarget    = "/usr/local/sbin/ugvm-backup"

	maxRequestBytes = 1 << 20
	maxStatusBytes  = 8 << 20
)

// Server holds the app's only powers: reading authorized folders and writing
// config.ini. It cannot touch VMs. All of that happens in the root script.
type Server struct {
	sharedDir       string
	dataDir         string
	installDir      string
	hostPathAllowed func(string) bool
	mu              sync.Mutex
}

type settings struct {
	ConfigFolder string `json:"config_folder"`
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/state", s.handleState)
	mux.HandleFunc("GET /api/folders", s.handleFolders)
	mux.HandleFunc("PUT /api/settings", s.handleSettings)
	mux.HandleFunc("PUT /api/jobs", s.handleJobs)
	mux.HandleFunc("POST /api/jobs/{id}/run", s.handleRun)
	return requireAdmin(mux)
}

// requireAdmin relies on the headers the UGOS gateway sets after authenticating
// a request. Binding to loopback keeps other machines from reaching this port
// and forging them. Requests with a body must be JSON, which a cross-site form
// cannot send.
func requireAdmin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		if r.Header.Get("Ugreen-User-Type") != "admin" {
			writeError(w, http.StatusForbidden, "Administrators only")
			return
		}
		if r.Header.Get("Sec-Fetch-Site") == "cross-site" {
			writeError(w, http.StatusForbidden, "Cross-site request refused")
			return
		}
		if r.Method == http.MethodPut {
			mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
			if err != nil || mediaType != "application/json" {
				writeError(w, http.StatusUnsupportedMediaType, "JSON expected")
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		log.Printf("write response: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func readJSON(w http.ResponseWriter, r *http.Request, into any) bool {
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxRequestBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(into); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid request")
		return false
	}
	return true
}

// --- Settings -----------------------------------------------------------------

func (s *Server) loadSettings() settings {
	var loaded settings
	data, err := os.ReadFile(filepath.Join(s.dataDir, settingsFile))
	if err != nil {
		return loaded
	}
	if err := json.Unmarshal(data, &loaded); err != nil {
		log.Printf("settings file is damaged: %v", err)
		return settings{}
	}
	return loaded
}

func (s *Server) saveSettings(value settings) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	root, err := os.OpenRoot(s.dataDir)
	if err != nil {
		return err
	}
	defer root.Close()
	return writeAtomic(root, settingsFile, data)
}

// writeAtomic never leaves a half-written file for the script to read, and the
// rename replaces a planted symlink instead of writing through it.
func writeAtomic(root *os.Root, name string, data []byte) error {
	suffix := make([]byte, 8)
	if _, err := rand.Read(suffix); err != nil {
		return err
	}
	temporary := "." + name + "." + hex.EncodeToString(suffix)
	if err := root.WriteFile(temporary, data, 0o640); err != nil {
		return err
	}
	if err := root.Rename(temporary, name); err != nil {
		root.Remove(temporary)
		return err
	}
	return nil
}

// openConfigDir opens the ugvm-backup subfolder of the chosen folder, creating
// it when asked to, and returns its path on the host.
func (s *Server) openConfigDir(folder string, create bool) (*os.Root, string, error) {
	parent, hostPath, err := s.openFolder(folder)
	if err != nil {
		return nil, "", err
	}
	defer parent.Close()
	if create {
		if err := parent.MkdirAll(configSubfolder, 0o750); err != nil {
			return nil, "", errors.New("Can't create the config folder")
		}
	}
	dir, err := parent.OpenRoot(configSubfolder)
	if err != nil {
		return nil, "", errors.New("Can't open the config folder")
	}
	return dir, hostPath + "/" + configSubfolder, nil
}

// --- State --------------------------------------------------------------------

type setupInfo struct {
	InstallCommand   string `json:"install_command"`
	CronLine         string `json:"cron_line"`
	CheckCommand     string `json:"check_command"`
	UninstallCommand string `json:"uninstall_command"`
}

type stateResponse struct {
	Now            int64           `json:"now"`
	AppVersion     string          `json:"app_version"`
	ScriptVersion  string          `json:"script_version"`
	User           string          `json:"user"`
	Folders        []Folder        `json:"folders"`
	ConfigFolder   string          `json:"config_folder"`
	ConfigHostPath string          `json:"config_host_path"`
	ConfigError    string          `json:"config_error"`
	Jobs           []Job           `json:"jobs"`
	Status         json.RawMessage `json:"status"`
	Setup          *setupInfo      `json:"setup"`
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}

func (s *Server) buildSetup(configHostPath string) *setupInfo {
	quoted := shellQuote(configHostPath)
	return &setupInfo{
		InstallCommand: "sudo install -o root -g root -m 0755 " +
			shellQuote(filepath.Join(s.installDir, "libexec", "ugvm-backup.sh")) + " " + scriptTarget,
		// "%" starts a new line in a crontab unless it is escaped.
		CronLine:         "*/10 * * * * " + scriptTarget + " --config " + strings.ReplaceAll(quoted, "%", `\%`) + " >/dev/null 2>&1",
		CheckCommand:     "sudo " + scriptTarget + " --config " + quoted + " --check",
		UninstallCommand: "sudo rm -rf " + scriptTarget + " /var/lib/ugvm-backup",
	}
}

func (s *Server) handleState(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()

	response := stateResponse{
		Now:           time.Now().Unix(),
		AppVersion:    appVersion,
		ScriptVersion: scriptVersion,
		User:          r.Header.Get("Ugreen-User-Name"),
		Folders:       s.authorizedFolders(),
		Jobs:          []Job{},
		Status:        json.RawMessage("null"),
		ConfigFolder:  s.loadSettings().ConfigFolder,
	}

	if response.ConfigFolder != "" {
		dir, hostPath, err := s.openConfigDir(response.ConfigFolder, false)
		if err != nil {
			response.ConfigError = err.Error()
		} else {
			defer dir.Close()
			response.ConfigHostPath = hostPath
			response.Setup = s.buildSetup(hostPath)
			if data, err := readLimited(dir, configFile, maxConfigBytes); err == nil {
				if jobs, err := parseConfig(data); err == nil {
					response.Jobs = jobs
				} else {
					response.ConfigError = "config.ini is damaged: " + err.Error()
				}
			} else if !errors.Is(err, fs.ErrNotExist) {
				response.ConfigError = "Can't read config.ini"
			}
			if data, err := readLimited(dir, statusFile, maxStatusBytes); err == nil && json.Valid(data) {
				response.Status = data
			}
		}
	}
	writeJSON(w, http.StatusOK, response)
}

func readLimited(root *os.Root, name string, limit int64) ([]byte, error) {
	file, err := root.Open(name)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, errors.New("file too large")
	}
	return data, nil
}

// --- Actions ------------------------------------------------------------------

func (s *Server) handleFolders(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Query().Get("path")
	if path == "" {
		writeJSON(w, http.StatusOK, map[string]any{"folders": s.authorizedFolders()})
		return
	}
	listing, err := s.listDirectory(path)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, listing)
}

func (s *Server) handleSettings(w http.ResponseWriter, r *http.Request) {
	var request settings
	if !readJSON(w, r, &request) {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	dir, _, err := s.openConfigDir(request.ConfigFolder, true)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	defer dir.Close()

	if _, err := dir.Stat(configFile); errors.Is(err, fs.ErrNotExist) {
		if err := writeAtomic(dir, configFile, renderConfig(nil)); err != nil {
			writeError(w, http.StatusInternalServerError, "Can't write config.ini")
			return
		}
	}
	if err := s.saveSettings(request); err != nil {
		log.Printf("save settings: %v", err)
		writeError(w, http.StatusInternalServerError, "Can't save the settings")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handleJobs(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Jobs []Job `json:"jobs"`
	}
	if !readJSON(w, r, &request) {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	for index := range request.Jobs {
		if request.Jobs[index].ID == "" {
			request.Jobs[index].ID = newJobID()
		}
	}
	if err := validateJobs(request.Jobs); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	for _, job := range request.Jobs {
		if err := s.checkTarget(job); err != nil {
			writeError(w, http.StatusBadRequest, jobLabel(job)+": "+err.Error())
			return
		}
	}

	dir, _, err := s.openConfigDir(s.loadSettings().ConfigFolder, true)
	if err != nil {
		writeError(w, http.StatusBadRequest, "Choose a config folder first")
		return
	}
	defer dir.Close()
	if err := writeAtomic(dir, configFile, renderConfig(request.Jobs)); err != nil {
		log.Printf("write config: %v", err)
		writeError(w, http.StatusInternalServerError, "Can't write config.ini")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"jobs": request.Jobs})
}

func (s *Server) checkTarget(job Job) error {
	if job.Type == "snapshot" {
		return nil
	}
	relative, err := s.relativeFromHost(job.Target)
	if err != nil {
		return err
	}
	root, _, err := s.openFolder(relative)
	if err != nil {
		return err
	}
	return root.Close()
}

// handleRun leaves a request file behind. The script picks it up on its next run,
// so this process needs no way to start anything itself.
func (s *Server) handleRun(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !reJobID.MatchString(id) {
		writeError(w, http.StatusBadRequest, "Invalid job ID")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	dir, _, err := s.openConfigDir(s.loadSettings().ConfigFolder, false)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	defer dir.Close()

	data, err := readLimited(dir, configFile, maxConfigBytes)
	if err != nil {
		writeError(w, http.StatusBadRequest, "Can't read config.ini")
		return
	}
	jobs, err := parseConfig(data)
	if err != nil {
		writeError(w, http.StatusBadRequest, "config.ini is damaged")
		return
	}
	known := false
	for _, job := range jobs {
		known = known || job.ID == id
	}
	if !known {
		writeError(w, http.StatusNotFound, "Job not found")
		return
	}
	if err := dir.MkdirAll(requestsFolder, 0o750); err != nil {
		writeError(w, http.StatusInternalServerError, "Can't save the request")
		return
	}
	if err := dir.WriteFile(requestsFolder+"/"+id, nil, 0o640); err != nil {
		writeError(w, http.StatusInternalServerError, "Can't save the request")
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]bool{"ok": true})
}

func newJobID() string {
	suffix := make([]byte, 6)
	if _, err := rand.Read(suffix); err != nil {
		panic(err)
	}
	return "j-" + hex.EncodeToString(suffix)
}
