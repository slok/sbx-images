// Command manifest generates a manifest.json from config.yaml and built artifacts.
//
// It reads the build configuration, scans the build directory for artifacts,
// computes file sizes, and outputs a structured manifest for GitHub Releases.
//
// Usage:
//
//	go run ./cmd/manifest -version v0.1.0 -config config.yaml -build-dir build -commit abc123
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"gopkg.in/yaml.v3"
)

// Config represents the build configuration from config.yaml.
type Config struct {
	Kernel struct {
		Version   string `yaml:"version"`
		CIVersion string `yaml:"ci_version"`
	} `yaml:"kernel"`
	Firecracker struct {
		Version string `yaml:"version"`
	} `yaml:"firecracker"`
	Rootfs struct {
		Distro        string `yaml:"distro"`
		DistroVersion string `yaml:"distro_version"`
		Profile       string `yaml:"profile"`
	} `yaml:"rootfs"`
	Architectures []string `yaml:"architectures"`
}

// Manifest is the release manifest written to manifest.json.
type Manifest struct {
	SchemaVersion int                      `json:"schema_version"`
	Version       string                   `json:"version"`
	Artifacts     map[string]ArchArtifacts `json:"artifacts"`
	Firecracker   ManifestFirecracker      `json:"firecracker"`
	Build         ManifestBuild            `json:"build"`
}

// ArchArtifacts contains per-architecture artifact metadata.
type ArchArtifacts struct {
	Kernel KernelArtifact `json:"kernel"`
	Rootfs RootfsArtifact `json:"rootfs"`
}

// KernelArtifact describes the kernel binary.
type KernelArtifact struct {
	File      string `json:"file"`
	Version   string `json:"version"`
	Source    string `json:"source"`
	SizeBytes int64  `json:"size_bytes"`
}

// RootfsArtifact describes the rootfs image.
type RootfsArtifact struct {
	File          string `json:"file"`
	Distro        string `json:"distro"`
	DistroVersion string `json:"distro_version"`
	Profile       string `json:"profile"`
	SizeBytes     int64  `json:"size_bytes"`
}

// ManifestFirecracker describes the expected Firecracker version.
type ManifestFirecracker struct {
	Version string `json:"version"`
	Source  string `json:"source"`
}

// ManifestBuild contains build metadata.
type ManifestBuild struct {
	Date   string `json:"date"`
	Commit string `json:"commit"`
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		version    string
		configPath string
		buildDir   string
		commit     string
		outputPath string
	)

	flag.StringVar(&version, "version", "", "Release version (e.g. v0.1.0)")
	flag.StringVar(&configPath, "config", "config.yaml", "Path to config.yaml")
	flag.StringVar(&buildDir, "build-dir", "build", "Path to build output directory")
	flag.StringVar(&commit, "commit", "", "Git commit SHA")
	flag.StringVar(&outputPath, "output", "", "Output path for manifest.json (default: <build-dir>/manifest.json)")
	flag.Parse()

	if version == "" {
		return fmt.Errorf("-version is required")
	}

	if outputPath == "" {
		outputPath = filepath.Join(buildDir, "manifest.json")
	}

	cfg, err := loadConfig(configPath)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}

	manifest, err := buildManifest(cfg, version, buildDir, commit)
	if err != nil {
		return fmt.Errorf("building manifest: %w", err)
	}

	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling manifest: %w", err)
	}

	if err := os.WriteFile(outputPath, append(data, '\n'), 0o644); err != nil {
		return fmt.Errorf("writing manifest: %w", err)
	}

	fmt.Printf("Wrote manifest: %s\n", outputPath)
	return nil
}

func loadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("reading %s: %w", path, err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return Config{}, fmt.Errorf("parsing %s: %w", path, err)
	}

	if len(cfg.Architectures) == 0 {
		return Config{}, fmt.Errorf("no architectures defined in %s", path)
	}
	if cfg.Kernel.Version == "" {
		return Config{}, fmt.Errorf("kernel.version is required in %s", path)
	}
	if cfg.Firecracker.Version == "" {
		return Config{}, fmt.Errorf("firecracker.version is required in %s", path)
	}

	return cfg, nil
}

func buildManifest(cfg Config, version, buildDir, commit string) (Manifest, error) {
	artifacts := make(map[string]ArchArtifacts, len(cfg.Architectures))

	for _, arch := range cfg.Architectures {
		kernelFile := fmt.Sprintf("vmlinux-%s", arch)
		rootfsFile := fmt.Sprintf("rootfs-%s.ext4", arch)

		kernelSize, err := fileSize(filepath.Join(buildDir, kernelFile))
		if err != nil {
			return Manifest{}, fmt.Errorf("kernel artifact for %s: %w", arch, err)
		}

		rootfsSize, err := fileSize(filepath.Join(buildDir, rootfsFile))
		if err != nil {
			return Manifest{}, fmt.Errorf("rootfs artifact for %s: %w", arch, err)
		}

		artifacts[arch] = ArchArtifacts{
			Kernel: KernelArtifact{
				File:      kernelFile,
				Version:   cfg.Kernel.Version,
				Source:    fmt.Sprintf("firecracker-ci/%s", cfg.Kernel.CIVersion),
				SizeBytes: kernelSize,
			},
			Rootfs: RootfsArtifact{
				File:          rootfsFile,
				Distro:        cfg.Rootfs.Distro,
				DistroVersion: cfg.Rootfs.DistroVersion,
				Profile:       cfg.Rootfs.Profile,
				SizeBytes:     rootfsSize,
			},
		}
	}

	return Manifest{
		SchemaVersion: 1,
		Version:       version,
		Artifacts:     artifacts,
		Firecracker: ManifestFirecracker{
			Version: cfg.Firecracker.Version,
			Source:  "github.com/firecracker-microvm/firecracker",
		},
		Build: ManifestBuild{
			Date:   time.Now().UTC().Format(time.RFC3339),
			Commit: commit,
		},
	}, nil
}

func fileSize(path string) (int64, error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, fmt.Errorf("stat %s: %w", path, err)
	}
	return info.Size(), nil
}
