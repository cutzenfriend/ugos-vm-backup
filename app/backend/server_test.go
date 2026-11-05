package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

type fixture struct {
	t         *testing.T
	server    *Server
	handler   http.Handler
	volume    string
	sharedDir string
}

// newFixture builds a fake app layout: "backup" is an authorized shared folder
// and "secret" is a folder on the same disk that was not authorized.
func newFixture(t *testing.T) *fixture {
	t.Helper()
	base := t.TempDir()
	volume := filepath.Join(base, "volume1")
	shared := filepath.Join(base, "shared")
	data := filepath.Join(base, "data")
	for _, dir := range []string{filepath.Join(volume, "backup", "vm"), filepath.Join(volume, "secret"), shared, data} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(filepath.Join(volume, "backup"), filepath.Join(shared, "backup")); err != nil {
		t.Fatal(err)
	}
	server := &Server{
		sharedDir:  shared,
		dataDir:    data,
		installDir: "/var/packages/test.app",
		// The real rule needs /volumeN paths, which a test cannot create.
		hostPathAllowed: func(path string) bool { return strings.HasPrefix(path, volume) },
	}
	return &fixture{t: t, server: server, handler: server.routes(), volume: volume, sharedDir: shared}
}

func (f *fixture) do(method, path, body string, mutate ...func(*http.Request)) *httptest.ResponseRecorder {
	f.t.Helper()
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	request.Header.Set("Ugreen-User-Type", "admin")
	request.Header.Set("Ugreen-User-Name", "tester")
	if body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	for _, change := range mutate {
		change(request)
	}
	recorder := httptest.NewRecorder()
	f.handler.ServeHTTP(recorder, request)
	return recorder
}

func (f *fixture) selectConfigFolder() {
	f.t.Helper()
	if response := f.do("PUT", "/api/settings", `{"config_folder":"backup"}`); response.Code != http.StatusOK {
		f.t.Fatalf("select config folder: %d %s", response.Code, response.Body)
	}
}

func (f *fixture) configDir() string { return filepath.Join(f.volume, "backup", configSubfolder) }

func (f *fixture) target() string { return filepath.Join(f.volume, "backup", "vm") }

func validJob(target string) Job {
	return Job{
		Name: "Nightly", Type: "file", Enabled: true, IntervalHours: 24, At: "03:00",
		VMs: []string{"*"}, Target: target, KeepCount: 7, KeepDays: 30, RunningVM: "live",
	}
}

func (f *fixture) putJobs(jobs ...Job) *httptest.ResponseRecorder {
	f.t.Helper()
	body, err := json.Marshal(map[string][]Job{"jobs": jobs})
	if err != nil {
		f.t.Fatal(err)
	}
	return f.do("PUT", "/api/jobs", string(body))
}

func TestAccessControl(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*http.Request)
		want   int
	}{
		{"admin allowed", func(r *http.Request) {}, http.StatusOK},
		{"regular user refused", func(r *http.Request) { r.Header.Set("Ugreen-User-Type", "users") }, http.StatusForbidden},
		{"missing gateway header refused", func(r *http.Request) { r.Header.Del("Ugreen-User-Type") }, http.StatusForbidden},
		{"cross-site refused", func(r *http.Request) { r.Header.Set("Sec-Fetch-Site", "cross-site") }, http.StatusForbidden},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			f := newFixture(t)
			if got := f.do("GET", "/api/state", "", test.mutate).Code; got != test.want {
				t.Errorf("status = %d, want %d", got, test.want)
			}
		})
	}
}

func TestRequestsWithBodyMustBeJSON(t *testing.T) {
	f := newFixture(t)
	response := f.do("PUT", "/api/settings", `{"config_folder":"backup"}`, func(r *http.Request) {
		r.Header.Set("Content-Type", "text/plain")
	})
	if response.Code != http.StatusUnsupportedMediaType {
		t.Errorf("status = %d, want 415", response.Code)
	}
}

func TestFolderValidation(t *testing.T) {
	f := newFixture(t)
	refused := []string{
		`{"config_folder":"secret"}`,
		`{"config_folder":"../secret"}`,
		`{"config_folder":"backup/../../secret"}`,
		`{"config_folder":"/etc"}`,
		`{"config_folder":""}`,
		`{"config_folder":"backup/@system"}`,
		`{"config_folder":"backup/vm\nfoo"}`,
		`{"config_folder":"backup","extra":true}`,
	}
	for _, body := range refused {
		if response := f.do("PUT", "/api/settings", body); response.Code != http.StatusBadRequest {
			t.Errorf("%s: status = %d, want 400", body, response.Code)
		}
	}
}

func TestSelectingFolderCreatesEmptyConfig(t *testing.T) {
	f := newFixture(t)
	f.selectConfigFolder()
	data, err := os.ReadFile(filepath.Join(f.configDir(), configFile))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "version=1") {
		t.Errorf("config = %q", data)
	}
}

func TestSavedJobsRoundTrip(t *testing.T) {
	f := newFixture(t)
	f.selectConfigFolder()
	if response := f.putJobs(validJob(f.target())); response.Code != http.StatusOK {
		t.Fatalf("save: %d %s", response.Code, response.Body)
	}

	var state stateResponse
	if err := json.Unmarshal(f.do("GET", "/api/state", "").Body.Bytes(), &state); err != nil {
		t.Fatal(err)
	}
	if len(state.Jobs) != 1 {
		t.Fatalf("jobs = %+v, config error = %q", state.Jobs, state.ConfigError)
	}
	job := state.Jobs[0]
	if !regexp.MustCompile(`^j-[0-9a-f]{12}$`).MatchString(job.ID) {
		t.Errorf("generated ID = %q", job.ID)
	}
	if job.Name != "Nightly" || job.KeepCount != 7 || job.KeepDays != 30 || !job.Enabled || job.Target != f.target() {
		t.Errorf("job changed in round trip: %+v", job)
	}
}

func TestJobTargetMustBeAuthorized(t *testing.T) {
	f := newFixture(t)
	f.selectConfigFolder()
	targets := map[string]string{
		"folder not authorized": filepath.Join(f.volume, "secret"),
		"path escape":           f.target() + "/../../secret",
		"missing folder":        filepath.Join(f.volume, "backup", "nope"),
		"system path":           "/etc",
	}
	for name, target := range targets {
		t.Run(name, func(t *testing.T) {
			if response := f.putJobs(validJob(target)); response.Code != http.StatusBadRequest {
				t.Errorf("status = %d, want 400: %s", response.Code, response.Body)
			}
		})
	}
}

func TestNewlineCannotInjectConfigLines(t *testing.T) {
	f := newFixture(t)
	f.selectConfigFolder()
	for name, change := range map[string]func(*Job){
		"name":   func(j *Job) { j.Name = "x\ntarget=/etc" },
		"at":     func(j *Job) { j.At = "03:00\ntarget=/etc" },
		"vm":     func(j *Job) { j.VMs = []string{"a\ntarget=/etc"} },
		"target": func(j *Job) { j.Target = "x\ntarget=/etc" },
	} {
		t.Run(name, func(t *testing.T) {
			job := validJob(f.target())
			change(&job)
			if response := f.putJobs(job); response.Code != http.StatusBadRequest {
				t.Errorf("status = %d, want 400", response.Code)
			}
		})
	}
}

func TestJobValidation(t *testing.T) {
	for name, change := range map[string]func(*Job){
		"bad type":           func(j *Job) { j.Type = "rm" },
		"bad interval":       func(j *Job) { j.IntervalHours = 5 },
		"zero interval":      func(j *Job) { j.IntervalHours = 0 },
		"bad time":           func(j *Job) { j.At = "25:00" },
		"negative count":     func(j *Job) { j.KeepCount = -1 },
		"huge days":          func(j *Job) { j.KeepDays = 99999 },
		"no vms":             func(j *Job) { j.VMs = nil },
		"star with others":   func(j *Job) { j.VMs = []string{"*", "a"} },
		"shell in vm":        func(j *Job) { j.VMs = []string{"$(id)"} },
		"bad running mode":   func(j *Job) { j.RunningVM = "kill" },
		"snapshot with path": func(j *Job) { j.Type = "snapshot" },
		"bad id":             func(j *Job) { j.ID = "../x" },
	} {
		t.Run(name, func(t *testing.T) {
			job := validJob("/volume1/backup")
			job.ID = "job"
			change(&job)
			if err := validateJob(job); err == nil {
				t.Error("expected a validation error")
			}
		})
	}
}

func TestDuplicateJobIDsRefused(t *testing.T) {
	job := validJob("/volume1/backup")
	job.ID = "same"
	if err := validateJobs([]Job{job, job}); err == nil {
		t.Error("expected a duplicate error")
	}
}

func TestConfigFilePlantedSymlinkIsNotFollowed(t *testing.T) {
	f := newFixture(t)
	f.selectConfigFolder()
	victim := filepath.Join(f.volume, "secret", "victim")
	if err := os.WriteFile(victim, []byte("do not touch"), 0o644); err != nil {
		t.Fatal(err)
	}
	config := filepath.Join(f.configDir(), configFile)
	if err := os.Remove(config); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(victim, config); err != nil {
		t.Fatal(err)
	}

	f.putJobs(validJob(f.target()))

	data, err := os.ReadFile(victim)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "do not touch" {
		t.Errorf("file behind symlink was changed: %q", data)
	}
}

func TestStatusSymlinkDoesNotLeakFiles(t *testing.T) {
	f := newFixture(t)
	f.selectConfigFolder()
	secret := filepath.Join(f.volume, "secret", "shadow.json")
	if err := os.WriteFile(secret, []byte(`{"token":"TOP-SECRET"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(secret, filepath.Join(f.configDir(), statusFile)); err != nil {
		t.Fatal(err)
	}
	if body := f.do("GET", "/api/state", "").Body.String(); strings.Contains(body, "TOP-SECRET") {
		t.Errorf("response contains content from outside the folder: %s", body)
	}
}

func TestStatusIsPassedThroughOnlyWhenValid(t *testing.T) {
	f := newFixture(t)
	f.selectConfigFolder()
	path := filepath.Join(f.configDir(), statusFile)

	if err := os.WriteFile(path, []byte(`{"state":"idle"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	var state stateResponse
	json.Unmarshal(f.do("GET", "/api/state", "").Body.Bytes(), &state)
	if string(state.Status) != `{"state":"idle"}` {
		t.Errorf("status = %s", state.Status)
	}

	if err := os.WriteFile(path, []byte(`{"broken`), 0o644); err != nil {
		t.Fatal(err)
	}
	json.Unmarshal(f.do("GET", "/api/state", "").Body.Bytes(), &state)
	if string(state.Status) != "null" {
		t.Errorf("invalid status passed through: %s", state.Status)
	}
}

func TestDirectoryListingHidesLinksAndSystemFolders(t *testing.T) {
	f := newFixture(t)
	backup := filepath.Join(f.volume, "backup")
	for _, dir := range []string{"@system", ".hidden", "visible"} {
		if err := os.Mkdir(filepath.Join(backup, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(filepath.Join(f.volume, "secret"), filepath.Join(backup, "link")); err != nil {
		t.Fatal(err)
	}

	var listing DirectoryListing
	json.Unmarshal(f.do("GET", "/api/folders?path=backup", "").Body.Bytes(), &listing)
	if strings.Join(listing.Dirs, ",") != "visible,vm" {
		t.Errorf("dirs = %v", listing.Dirs)
	}

	// A planted link also cannot be opened directly.
	if response := f.do("GET", "/api/folders?path=backup/link", ""); response.Code != http.StatusBadRequest {
		t.Errorf("symlink to outside folder: status = %d, want 400", response.Code)
	}
}

func TestRunRequest(t *testing.T) {
	f := newFixture(t)
	f.selectConfigFolder()
	job := validJob(f.target())
	job.ID = "nightly"
	if response := f.putJobs(job); response.Code != http.StatusOK {
		t.Fatalf("save: %s", response.Body)
	}

	if response := f.do("POST", "/api/jobs/nightly/run", ""); response.Code != http.StatusAccepted {
		t.Fatalf("status = %d: %s", response.Code, response.Body)
	}
	if _, err := os.Stat(filepath.Join(f.configDir(), requestsFolder, "nightly")); err != nil {
		t.Errorf("request file missing: %v", err)
	}
	if response := f.do("POST", "/api/jobs/unknown/run", ""); response.Code != http.StatusNotFound {
		t.Errorf("unknown job: status = %d, want 404", response.Code)
	}
	if response := f.do("POST", "/api/jobs/..%2f..%2fx/run", ""); response.Code == http.StatusAccepted {
		t.Error("path traversal in job ID was accepted")
	}
}

func TestHostPathRule(t *testing.T) {
	allowed := []string{"/volume1/backup", "/volume12/a/b c/d", "/volume1/café"}
	refused := []string{
		"/volume1", "/etc", "/volume1/@kvm", "/volume1/a/@b", "/volume1/../etc",
		"/volume1/a/..", "/volume1/a\nb", "volume1/a", "/volumes/a", "/home/user/documents",
	}
	for _, path := range allowed {
		if !isAllowedHostPath(path) {
			t.Errorf("%q should be allowed", path)
		}
	}
	for _, path := range refused {
		if isAllowedHostPath(path) {
			t.Errorf("%q should be refused", path)
		}
	}
}

func TestShellQuoteInSetupCommands(t *testing.T) {
	f := newFixture(t)
	setup := f.server.buildSetup("/volume1/it's 100%/ugvm-backup")
	if !strings.Contains(setup.CheckCommand, `'/volume1/it'\''s 100%/ugvm-backup'`) {
		t.Errorf("check command = %s", setup.CheckCommand)
	}
	if !strings.Contains(setup.CronLine, `100\%`) {
		t.Errorf("percent sign not escaped for cron: %s", setup.CronLine)
	}
}

func TestScriptVersionMatchesBundledScript(t *testing.T) {
	data, err := os.ReadFile("../rootfs_common/libexec/ugvm-backup.sh")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `readonly VERSION="`+scriptVersion+`"`) {
		t.Errorf("scriptVersion %q does not match the script", scriptVersion)
	}
}

// The script and the app must agree on what config.ini looks like.
func TestRenderedConfigFormat(t *testing.T) {
	job := validJob("/volume1/backup")
	job.ID = "nightly"
	got := string(renderConfig([]Job{job}))
	for _, line := range []string{"version=1", "[job]", "id=nightly", "type=file", "enabled=1",
		"interval_hours=24", "at=03:00", "vms=*", "keep_count=7", "keep_days=30",
		"target=/volume1/backup", "running_vm=live"} {
		if !strings.Contains(got, line+"\n") {
			t.Errorf("config lacks %q:\n%s", line, got)
		}
	}
	snapshot := Job{ID: "s", Type: "snapshot", IntervalHours: 6, At: "00:00", VMs: []string{"a", "b"}}
	if rendered := string(renderConfig([]Job{snapshot})); strings.Contains(rendered, "target=") || !strings.Contains(rendered, "vms=a,b\n") {
		t.Errorf("snapshot config:\n%s", rendered)
	}
}
