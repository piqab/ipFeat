# VPS setup for ipFeat

ipFeat can create a matching sing-box client and server configuration for a new Linux VPS. The server must have public IPv4, systemd, Bash, `tar`, and `sha256sum`. The installer supports `x86_64` and `aarch64`/`arm64`. It can install `curl` and a JSON parser with the host package manager when needed.

## Create a connection

1. Open **sing-box → Client connections → New server**.
2. Enter the VPS IPv4 address and SSH port. Choose a protocol and its TLS or Reality settings.
3. Review and validate both JSON files. The wizard pins the selected official sing-box version to both sides.
4. Install over SSH, or copy one of the manual installation scripts.

The SSH installation window shows each command, remote output, and exit status. After installation, ipFeat opens a separate SSH session and verifies the config hash, binary version, files, and active and enabled systemd unit. A failed or interrupted check leaves the connection pending so it can be completed later.

## Manual installation

**Copy VPS installation script** creates a standalone script for the VPS. Run it as root on the VPS. **Copy host installation script** creates a self-contained script for a Mac or Linux computer that can reach both GitHub and the VPS. The host script downloads the official release over IPv4, checks its published SHA-256 digest, and transfers the archive and installer over SSH.

Successful manual installation prints an `IPFEAT_INSTALL_OK` line. Paste that full line into **sing-box → Client connections → Pending manual installations → Complete installation**. The receipt must match the saved installation ID, sing-box version, and server JSON hash. The connection remains marked **Installation not verified** until ipFeat checks it directly over SSH.

The copied scripts contain the server JSON and credentials. Keep them private and remove unused copies when finished.

## Existing servers

Open **Installation / Check…** for a saved connection to inspect the service and its recent journal. If it finds a verified `ipinformer-sing-box` service from IP Informer, use **Migrate previous service to ipFeat** with SSH authorization. The migration copies the config and binary, switches systemd to `ipfeat-sing-box`, verifies the new service, and restores the old service if startup fails. The old server files remain as a rollback copy until ipFeat removes the migrated service. Remote deletion also recognizes the old service name.

**Client JSON** and **Share QRS** provide standalone client configurations. QRS includes client credentials and enabled global domain routes. Reimport it after changing domain routes on the Mac. The official sing-box Android client uses the Android device's own network for `direct`.
