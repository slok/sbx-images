# sbx-images

Pre-built VM images (kernel + rootfs) for [sbx](https://github.com/slok/sbx).

Each release contains:

- `vmlinux-{arch}` - Linux kernel binary from Firecracker CI
- `rootfs-{arch}.ext4` - Alpine Linux ext4 rootfs
- `manifest.json` - Release manifest with artifact metadata

## Usage

Images are consumed by `sbx image pull`:

```bash
sbx image pull v0.1.0
sbx create --from-image v0.1.0 my-sandbox
```

## Building locally

```bash
# Build all artifacts (requires sudo for rootfs).
make build

# Generate manifest.json from built artifacts.
make manifest VERSION=v0.1.0
```

## Configuration

Build parameters are defined in `config.yaml`:

- Kernel version and Firecracker CI source
- Rootfs distro, version, and package profile
- Firecracker version (metadata only, binary not bundled)
- Target architectures

## Release process

1. Update `config.yaml` if needed
2. Push changes via PR, CI validates the build
3. Create and push a semver tag: `git tag v0.1.0 && git push origin v0.1.0`
4. Release workflow builds artifacts and creates a GitHub Release
