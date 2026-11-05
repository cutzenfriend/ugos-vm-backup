package main

import (
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode"
)

const (
	configFormat   = 1
	maxConfigBytes = 64 * 1024
	maxJobs        = 32
	maxJobNameLen  = 64
	allVMs         = "*"
)

// Allowed intervals. Values below a day divide 24 so runs line up with midnight,
// which is also enforced by the backup script.
var allowedIntervalHours = []int{1, 2, 3, 4, 6, 8, 12, 24, 48, 72, 168, 336, 720}

var (
	reJobID = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)
	reVMID  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
	reTime  = regexp.MustCompile(`^([01][0-9]|2[0-3]):[0-5][0-9]$`)
)

// Job is one backup job. The backup script validates the same rules again,
// because it must not trust anything this process writes.
type Job struct {
	ID            string   `json:"id"`
	Name          string   `json:"name"`
	Type          string   `json:"type"`
	Enabled       bool     `json:"enabled"`
	IntervalHours int      `json:"interval_hours"`
	At            string   `json:"at"`
	VMs           []string `json:"vms"`
	Target        string   `json:"target"`
	KeepCount     int      `json:"keep_count"`
	KeepDays      int      `json:"keep_days"`
	RunningVM     string   `json:"running_vm"`
}

// validateJob checks everything that does not depend on the file system.
func validateJob(job Job) error {
	if !reJobID.MatchString(job.ID) {
		return errors.New("Invalid job ID")
	}
	if len(job.Name) > maxJobNameLen || strings.ContainsFunc(job.Name, unicode.IsControl) {
		return errors.New("Invalid name")
	}
	switch job.Type {
	case "snapshot":
		if job.Target != "" || job.RunningVM != "" {
			return errors.New("Snapshots have no target folder")
		}
	case "file", "ova":
		if job.Target == "" {
			return errors.New("Choose a target folder")
		}
		if !slices.Contains([]string{"live", "shutdown", "skip"}, job.RunningVM) {
			return errors.New("Invalid setting for running VMs")
		}
	default:
		return errors.New("Invalid type")
	}
	if !slices.Contains(allowedIntervalHours, job.IntervalHours) {
		return errors.New("Invalid interval")
	}
	if !reTime.MatchString(job.At) {
		return errors.New("Invalid time")
	}
	if job.KeepCount < 0 || job.KeepCount > 1000 {
		return errors.New("Backup count must be between 0 and 1000")
	}
	if job.KeepDays < 0 || job.KeepDays > 3650 {
		return errors.New("Retention must be between 0 and 3650 days")
	}
	if len(job.VMs) == 0 {
		return errors.New("Choose at least one VM")
	}
	if slices.Contains(job.VMs, allVMs) {
		if len(job.VMs) != 1 {
			return errors.New("Invalid VM selection")
		}
		return nil
	}
	for _, vm := range job.VMs {
		if !reVMID.MatchString(vm) {
			return errors.New("Invalid VM ID")
		}
	}
	return nil
}

func validateJobs(jobs []Job) error {
	if len(jobs) > maxJobs {
		return fmt.Errorf("At most %d jobs", maxJobs)
	}
	seen := map[string]bool{}
	for _, job := range jobs {
		if err := validateJob(job); err != nil {
			return fmt.Errorf("%s: %w", jobLabel(job), err)
		}
		if seen[job.ID] {
			return fmt.Errorf("%s: duplicate job ID", jobLabel(job))
		}
		seen[job.ID] = true
	}
	return nil
}

func jobLabel(job Job) string {
	if job.Name != "" {
		return "Job " + strconv.QuoteToGraphic(job.Name)
	}
	return "Job"
}

func renderConfig(jobs []Job) []byte {
	var out strings.Builder
	out.WriteString("# Managed by the VM Backup app. Manual changes may be overwritten.\n")
	fmt.Fprintf(&out, "version=%d\n", configFormat)
	for _, job := range jobs {
		enabled := 0
		if job.Enabled {
			enabled = 1
		}
		out.WriteString("\n[job]\n")
		fmt.Fprintf(&out, "id=%s\nname=%s\ntype=%s\nenabled=%d\n", job.ID, job.Name, job.Type, enabled)
		fmt.Fprintf(&out, "interval_hours=%d\nat=%s\nvms=%s\n", job.IntervalHours, job.At, strings.Join(job.VMs, ","))
		fmt.Fprintf(&out, "keep_count=%d\nkeep_days=%d\n", job.KeepCount, job.KeepDays)
		if job.Type != "snapshot" {
			fmt.Fprintf(&out, "target=%s\nrunning_vm=%s\n", job.Target, job.RunningVM)
		}
	}
	return []byte(out.String())
}

// parseConfig reads config.ini back for display. It stays strict so a damaged
// or tampered file shows up as an error instead of being silently rewritten.
func parseConfig(data []byte) ([]Job, error) {
	jobs := []Job{}
	version := ""
	var current *Job
	for number, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSuffix(line, "\r")
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if line == "[job]" {
			jobs = append(jobs, Job{})
			current = &jobs[len(jobs)-1]
			continue
		}
		key, value, found := strings.Cut(line, "=")
		if !found {
			return nil, fmt.Errorf("Invalid line %d", number+1)
		}
		if key == "version" {
			version = value
			continue
		}
		if current == nil {
			return nil, fmt.Errorf("Invalid line %d", number+1)
		}
		if err := setJobField(current, key, value); err != nil {
			return nil, fmt.Errorf("Line %d: %w", number+1, err)
		}
	}
	if version != strconv.Itoa(configFormat) {
		return nil, errors.New("Unsupported config version")
	}
	if err := validateJobs(jobs); err != nil {
		return nil, err
	}
	return jobs, nil
}

func setJobField(job *Job, key, value string) error {
	var err error
	switch key {
	case "id":
		job.ID = value
	case "name":
		job.Name = value
	case "type":
		job.Type = value
	case "enabled":
		job.Enabled = value == "1"
	case "interval_hours":
		job.IntervalHours, err = strconv.Atoi(value)
	case "at":
		job.At = value
	case "vms":
		job.VMs = strings.Split(value, ",")
	case "target":
		job.Target = value
	case "keep_count":
		job.KeepCount, err = strconv.Atoi(value)
	case "keep_days":
		job.KeepDays, err = strconv.Atoi(value)
	case "running_vm":
		job.RunningVM = value
	default:
		return errors.New("Unknown key")
	}
	if err != nil {
		return errors.New("Invalid number")
	}
	return nil
}
