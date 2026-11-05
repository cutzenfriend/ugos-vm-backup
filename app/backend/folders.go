package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"unicode"
)

// Mirrors the rule in the backup script: shared folders on a volume, nothing in
// system ("@") folders such as @kvm or @appstore.
var reHostPath = regexp.MustCompile(`^/volume[0-9]+(/[^/]+)+$`)

func isAllowedHostPath(path string) bool {
	if !reHostPath.MatchString(path) || strings.ContainsFunc(path, unicode.IsControl) {
		return false
	}
	for _, part := range strings.Split(path, "/") {
		if part == "." || part == ".." || strings.HasPrefix(part, "@") {
			return false
		}
	}
	return true
}

// Folder is a shared folder the user authorized for this app on its UGOS
// settings page. UGOS exposes each one as a symlink in UGAPP_SHARED_DIR.
type Folder struct {
	Name     string `json:"name"`
	HostPath string `json:"host_path"`
	Usable   bool   `json:"usable"`
	Reason   string `json:"reason,omitempty"`
}

func (s *Server) authorizedFolders() []Folder {
	entries, err := os.ReadDir(s.sharedDir)
	if err != nil {
		return []Folder{}
	}
	folders := make([]Folder, 0, len(entries))
	for _, entry := range entries {
		folder := Folder{Name: entry.Name()}
		link := filepath.Join(s.sharedDir, entry.Name())
		target, err := os.Readlink(link)
		switch {
		case err != nil:
			folder.Reason = "Can't determine this folder's path"
		case !filepath.IsAbs(target):
			folder.Reason = "Can't determine this folder's path"
		case !s.hostPathAllowed(filepath.Clean(target)):
			folder.HostPath = target
			folder.Reason = "Only shared folders on a volume can be used"
		default:
			folder.HostPath = filepath.Clean(target)
			folder.Usable = true
		}
		folders = append(folders, folder)
	}
	return folders
}

// splitRelative splits "<folder>/<sub/path>" and rejects anything that is not a
// plain descending path.
func splitRelative(rel string) (name, sub string, err error) {
	if rel == "" || strings.ContainsFunc(rel, unicode.IsControl) || len(rel) > 1024 {
		return "", "", errors.New("Invalid folder")
	}
	parts := strings.Split(rel, "/")
	for _, part := range parts {
		if part == "" || part == "." || part == ".." || strings.HasPrefix(part, "@") || strings.ContainsRune(part, '\\') {
			return "", "", errors.New("Invalid folder")
		}
	}
	return parts[0], strings.Join(parts[1:], "/"), nil
}

// openFolder opens an authorized folder as an os.Root. Every later access through
// the root is confined to it, so a symlink planted inside a shared folder cannot
// lead the app anywhere else.
func (s *Server) openFolder(rel string) (*os.Root, string, error) {
	name, sub, err := splitRelative(rel)
	if err != nil {
		return nil, "", err
	}
	index := slices.IndexFunc(s.authorizedFolders(), func(f Folder) bool { return f.Name == name && f.Usable })
	if index < 0 {
		return nil, "", errors.New("This folder isn't authorized for the app")
	}
	hostPath := s.authorizedFolders()[index].HostPath

	root, err := os.OpenRoot(filepath.Join(s.sharedDir, name))
	if err != nil {
		return nil, "", fmt.Errorf("Can't read folder: %s", name)
	}
	if sub == "" {
		return root, hostPath, nil
	}
	defer root.Close()
	subRoot, err := root.OpenRoot(sub)
	if err != nil {
		return nil, "", errors.New("Subfolder not found")
	}
	return subRoot, hostPath + "/" + sub, nil
}

// relativeFromHost maps a stored host path back to "<folder>/<sub>". Only paths
// inside authorized folders resolve, so a request cannot name an arbitrary target.
func (s *Server) relativeFromHost(hostPath string) (string, error) {
	for _, folder := range s.authorizedFolders() {
		if !folder.Usable {
			continue
		}
		if hostPath == folder.HostPath {
			return folder.Name, nil
		}
		if sub, ok := strings.CutPrefix(hostPath, folder.HostPath+"/"); ok {
			return folder.Name + "/" + sub, nil
		}
	}
	return "", errors.New("The target folder isn't authorized for the app")
}

// DirectoryListing is one level of the folder picker.
type DirectoryListing struct {
	Path     string   `json:"path"`
	HostPath string   `json:"host_path"`
	Dirs     []string `json:"dirs"`
}

func (s *Server) listDirectory(rel string) (DirectoryListing, error) {
	root, hostPath, err := s.openFolder(rel)
	if err != nil {
		return DirectoryListing{}, err
	}
	defer root.Close()

	dir, err := root.Open(".")
	if err != nil {
		return DirectoryListing{}, errors.New("Can't read folder")
	}
	defer dir.Close()
	entries, err := dir.ReadDir(-1)
	if err != nil {
		return DirectoryListing{}, errors.New("Can't read folder")
	}

	dirs := []string{}
	for _, entry := range entries {
		name := entry.Name()
		// Type() does not follow symlinks, so links never appear in the picker.
		if entry.Type().IsDir() && !strings.HasPrefix(name, ".") && !strings.HasPrefix(name, "@") && name != configSubfolder {
			dirs = append(dirs, name)
		}
	}
	slices.Sort(dirs)
	return DirectoryListing{Path: rel, HostPath: hostPath, Dirs: dirs}, nil
}
