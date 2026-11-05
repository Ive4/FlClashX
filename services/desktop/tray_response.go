package main

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
)

func (h *host) readTrayResponse(response trayResponse) (trayResponse, error) {
	path := filepath.Clean(response.File)
	if !filepath.IsAbs(path) || filepath.Dir(path) != filepath.Join(h.config.Home, "responses") || filepath.Ext(path) != ".json" {
		return trayResponse{}, errors.New("invalid tray response path")
	}
	root, err := os.OpenRoot(filepath.Join(h.config.Home, "responses"))
	if err != nil {
		return trayResponse{}, err
	}
	defer root.Close()
	file, err := root.Open(filepath.Base(path))
	if err != nil {
		return trayResponse{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxFrameSize {
		return trayResponse{}, errors.New("invalid tray response file")
	}
	data, err := io.ReadAll(io.LimitReader(file, maxFrameSize+1))
	if err != nil || len(data) > maxFrameSize {
		return trayResponse{}, errors.New("tray response exceeds frame limit")
	}
	var spilled trayResponse
	if err := json.Unmarshal(data, &spilled); err != nil {
		return trayResponse{}, err
	}
	if spilled.ID != response.ID || spilled.File != "" {
		return trayResponse{}, errors.New("invalid spilled tray response")
	}
	file.Close()
	if err := root.Remove(filepath.Base(path)); err != nil {
		return trayResponse{}, err
	}
	return spilled, nil
}
