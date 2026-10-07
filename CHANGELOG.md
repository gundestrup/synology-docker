# Changelog

## Unreleased

- Made `--stage` skip iptables kernel-module and AppArmor installation. Staging should prepare and inspect an update without mutating host configuration.
- Shell-escaped every argument in generated container recreation commands and preserved command arguments individually. Container metadata must not become executable shell syntax when a suggested command is copied.
- Stopped update and restore workflows when binary, ownership, permissions, log-driver, or restore-file operations fail; logger configuration now uses a temporary file and reports invalid JSON or replacement failures. Continuing after a partial install could leave Docker in a mixed or unusable state while reporting success.
- Downloaded iptables modules into a private temporary directory and removed only that directory. The installer must not overwrite or delete same-named files in the caller's working directory.
- Preserved Compose paths containing spaces when sorting and checking container records so valid project files are not misclassified.
- Restricted service-control workflows to DSM 6 and 7 and made unsupported versions fail explicitly. The service-control implementation has no verified path for later major versions.
- Added Docker-based mocked regression tests and a read-only DSM runtime capability probe that accepts DSM 6/7 only and checks the version-specific service manager. The mocks catch command-rendering regressions without touching a live Docker service; the probe helps identify DSM-specific missing tools.
- Documented a DSM 6/7 manual integration matrix, keeping DSM 6 on physical hardware because the Virtual DSM DSM 6 path has a known stability issue.
- Failed closed when release lookup fails or an automatic target would downgrade Docker; an older offline Docker archive also requires `--force`. Explicit update downgrades need both `--force` and a target version, while force and offline install still prepare required modules and AppArmor.
- Made backups private, verified, and non-overwriting; included managed AppArmor profile state when present and checked archive extraction and individual restore copies so failures cannot be mistaken for successful rollbacks.
- Kept staged downloads in a per-run private directory and stopped deleting offline install inputs. Forwarding edits now fail on missing anchors or write errors without partially editing the live script, and failed service starts always exit nonzero.
- Pinned kernel modules to an upstream commit and verified platform-specific SHA-256 digests before installation. The AppArmor wrapper/profile installer now prepares files before replacement, restores its parser and files on failure, and only removes managed profiles on restore.
- Redacted container environment values from recreate suggestions, required an operator-supplied env file, preserved explicit port bind IPs, read-only/named mounts, TTY settings, restart policy, network mode, and entrypoint; recreated containers use the `local` logger, and the listing includes stopped containers.
- Added a Synology Container Manager JSON/Docker inspect converter that generates a reviewed Compose file and private environment file, simplifying recovery of non-Compose containers stuck on the removed `db` logger. The container listing can convert one named container or all non-Compose containers with `--compose-dir`; repeat runs report unchanged output as already converted and write differing candidates as `.generated` files instead of overwriting reviewed files.
