# Engineering Knowledge Base: Container Project

This document provides a technical overview and institutional knowledge for AI agents and developers working on the `container` project.

## 1. DNS Infrastructure

The project uses a modular DNS resolution system located in `Sources/DNSServer`.

### Architecture
- **DNSHandler Protocol**: Defines a standard interface for responding to DNS queries.
- **CompositeResolver**: A chain-of-responsibility pattern that iterates through multiple handlers.
- **Handler Chain Order**:
  1. `LocalhostDNSHandler` or `ContainerDNSHandler`: Resolves internal/container-specific names.
  2. `ForwardingResolver`: Forwards unhandled queries to upstream system nameservers (from `/etc/resolv.conf`).
  3. `NxDomainResolver`: Returns NXDOMAIN as a final fallback.

### Ports and Listeners
- **Port 2053**: Listener for container-to-container hostname resolution.
- **Port 1053**: Listener for localhost redirects.

### Prevention of Recursive Loops
- When implementing `ForwardingResolver`, it is critical to filter out loopback addresses (`127.0.0.1`, `::1`, `localhost`) from the upstream nameserver list. If the host's `/etc/resolv.conf` points back to the container API server, failing to filter these will cause infinite recursion.

## 2. Network Management

### Lifecycle and Deletion
- Network configurations are managed by `NetworksService` (actor) and persisted via `FilesystemEntityStore`.
- **Atomic Deletion**: Deleting a network requires verifying that no active containers are attached to it. This is handled via `containersService.withContainerList`.
- **Allocator Logic**: Each network has an `AttachmentAllocator` that manages IP and MAC address assignments.

### Networking Backend
- **vmnet**: The network plugin (`container-network-vmnet`) leverages macOS `vmnet.framework` to create shared network interfaces (NAT mode), enabling communication between the host and the VM-based containers.

### Port Forwarding (SocketForwarder)
- This mechanism enables access to container services from the host (e.g., `container run -p 8080:80`).
- **Mechanism**: The system listens on a host port and proxies traffic to the container's IP and port.
- **Implementation**: `TCPForwarder` and `UDPForwarder` use SwiftNIO to handle bidirectional traffic asynchronously.

## 3. Storage and Resource Management

### Image Management
- **OCI Layout**: Images are stored in the `images/` directory following the OCI image layout specification.
- **RootFS Snapshots**: When a container is created, a copy-on-write snapshot (using APFS clones) of the image's rootfs is created in the container's bundle. This allows for near-instant container creation and minimal disk overhead.
- **Init Image**: A special `init` image is used to bootstrap the container's internal environment before the main workload starts.

### Volume Management
- **Persistence**: Volumes are managed by `VolumesService` and stored in the `volumes/` directory.
- **virtiofs**: Volumes are mounted into the Linux guest using `virtiofs`, providing high-performance file sharing between the macOS host and the container.

### Kernel Management
- **Kernel Service**: The `KernelService` manages Linux kernel and initrd artifacts used to boot containers.
- **Virtualization Integration**: Kernels are stored in the `kernels/` directory and loaded via the `VZLinuxBootLoader` provided by Apple's `Virtualization.framework`.

### Resource Bundles
- Persistent data is stored under the application root (e.g., `~/Library/Application Support/com.apple.container/`).
- **Container Bundles**: Located in `containers/[ID]/`.
    - `config.json`: OCI-compatible container configuration.
    - `rootfs/`: The container's root filesystem.
    - `options.json`: High-level options like `autoRemove`.
    - `logs/` and `boot.log`: Execution and boot history.
- **Entity Store**: The `FilesystemEntityStore` handles atomic serialization of configurations to disk.

## 4. System Architecture

### Service Management
- **APIServer**: The central orchestrator (`Sources/Helpers/APIServer`). It manages XPC routes for container, network, and plugin operations.
- **XPC Communication**: The CLI (`container`) communicates with the `container-apiserver` via XPC.

### Interaction Flow (High-level)
1. **CLI**: Sends an XPC request to the **APIServer**.
2. **APIServer**: Orchestrates the request by calling the **Network Plugin** (for IP allocation) and the **Runtime Plugin** (for VM lifecycle).
3. **Runtime Plugin**: Leverages `Virtualization.framework` to boot the VM and starts **SocketForwarders** for port mapping.
4. **Guest Agent**: Runs inside the VM to execute the actual OCI container process.

### Plugins and Discovery
- The system is extensible via plugins. `PluginLoader` discovers binaries in several standard locations.
- **Registration Arguments**: When registering a plugin with `launchd`, the API server passes standard arguments:
    - `--id`: Instance identifier.
    - `--service-identifier`: The Mach service name for XPC.
    - `--plugin-state-root`: Directory for persistent state.
- **Plugin Responsibilities**: Plugins run as independent XPC services, responding to commands like `allocate`, `start`, or `stop` from the API server.

### Application Data Root
- The default root is `~/Library/Application Support/com.apple.container`.
- This can be overridden using the environment variable `CONTAINER_APP_ROOT`.

## 5. XPC and Service Lifecycle

### launchd Integration
- The API server dynamically registers plugins as `launchd` services.
- **Service Labels**: Typically follow the pattern `user/[UID]/com.apple.container.[plugin].[instance]`.
- **Stale Services**: If a service fails to stop, it may remain in `launchctl`. This can cause "busy" errors during network deletion or port conflicts. Use `container system stop` to clean up.

### Exit Monitoring
- The `ExitMonitor` track the lifecycle of container processes.
- When a container exits, the monitor triggers cleanup tasks, including resource deallocation and, if configured, automatic bundle removal (`autoRemove`).
- **Exit Code 137**: Indicates the container was forcefully killed with `SIGKILL`. This typically occurs during `container stop` if the workload fails to exit within the default graceful shutdown timeout (5 seconds).
- **Naming Collisions**: Since XPC service labels include the container ID, manually named containers (e.g., `--name test-add-host`) may collide with automated test suites running in the background, leading to unexpected `stop` or `kill` commands being routed to the wrong instance.

### Keychain Access and Security Context
*   **Service Restriction**: Background services managed by `launchd` (like `container-core-images`) cannot access the user's login keychain directly. Attempting to do so results in `errSecInteractionNotAllowed` (status: -25308).
*   **Authentication Flow**: Credentials must be retrieved by the CLI (`container`), which runs in the user's active session, and then passed to the background services via XPC.
*   **Implementation Note**: When passing `Authentication` objects over XPC, use a serializable intermediate structure (e.g., `XPCAuth`) to wrap `username` and `password`. The background service then reconstructs the `BasicAuthentication` object to interact with the registry.
*   **Registry Hostname Normalization**: When performing keychain lookups for image registries, the hostname must be normalized. For example, `docker.io` should be treated as `registry-1.docker.io` to ensure credentials stored via `container registry login` (which often uses the canonical registry host) are correctly found.

### Code Signing
- macOS requires proper code signing for XPC communication and `Virtualization.framework`.
- The `Makefile` handles signing automatically. If you manually replace binaries, ensure they are signed, or XPC connections will be dropped by the system.

## 6. Communication Protocol

### XPC Internals
- **Message Format**: Most communication uses the `XPCMessage` class, which internally wraps `xpc_dictionary_t`.
- **Serialization**: `Codable` objects (e.g., `ContainerConfiguration`, `NetworkState`) are serialized to JSON and stored as data within the XPC dictionary using specific keys.
- **Async/Await Bridge**: The system uses a bridge between Apple's XPC C-API and Swift's structured concurrency, allowing for clean `await client.send(request)` patterns.

## 7. Development and Debugging

### Build System and Staging
- The project uses a `Makefile` that wraps `swift build`.
- **Staging Directory**: `bin/debug/staging` mimics the production install structure:
  - `bin/`: Contains `container` and `container-apiserver`.
  - `libexec/container/plugins/`: Contains plugin subdirectories (e.g., `container-network-vmnet/bin/...`).
- Binary output location for direct access: `bin/container`.

### Swift PM Workspace State
- **CRITICAL**: Always check `.build/workspace-state.json` at the start of a session. This file indicates if a package is in "edit" mode (via `swift package edit`) or if its location has been overridden by a local path.
- Failing to check this can lead to confusion if you are unknowingly editing or debugging a local version of a dependency instead of the upstream one.
- **Example**: If `containerization` is being developed locally, its entry in `workspace-state.json` will point to the local path (e.g., `../containerization`). This is crucial for verifying that the expected code is being linked and compiled.

### Debugging Logs
- Use `container system logs` to stream logs from all active background services.
- Individual component logs are often stored in the container bundle or under the `Application Support` root.

### Common Issues
- **DNS Resolution in RUN**: If `RUN` commands in Dockerfiles fail to resolve internet domains, ensure the `ForwardingResolver` is correctly placed in the `CompositeResolver` chain and that it can access the host's nameservers.
- **Network Deletion Failures**: Often caused by stale "busy" states or incorrect checks for active containers. Prefer actor-level locks and atomic state checks over manual allocator disabling when the higher-level service already guarantees safety. (Note: Redundant checks in the network plugin can cause false "busy" errors even when no containers are attached.)
- **Keychain Error -25308**: If `container image pull` fails with an unhandled error status -25308, it indicates the background service is attempting to access the keychain without a proper security context. Ensure the lookup is performed on the client side.
- **Registry Authentication (GHCR 403)**: Some registries (like GHCR) return multiple authentication challenges (Bearer + Basic) in the `WWW-Authenticate` header. The `containerization` library uses a `Scanner`-based parser to correctly handle comma-separated challenges and key-value pairs (including quoted strings and spaces), ensuring that `Bearer` challenges are correctly identified and processed.

## 8. Quick Reference (Cheat Sheet)

- **Force Restart System**: `bin/container system stop && bin/container system start`
- **Check Service Status**: `launchctl list | grep com.apple.container`
- **Test Internal DNS**: `dig @127.0.0.1 -p 2053 [hostname]`
- **View All Logs**: `bin/container system logs`
- **Clean Environment**: `CONTAINER_APP_ROOT=/tmp/container bin/container system start` (uses a fresh state)

## 9. Technology Stack
- **Language**: Swift 6 (using Concurrency features like Actors and `NIOAsyncChannel`).
- **Virtualization**: Uses Apple's `Virtualization.framework` to run Linux guest environments.
- **Networking**: SwiftNIO, DNSClient, and the custom `DNSServer` module.
- **CLI**: Swift Argument Parser.
- **Target OS**: macOS 15.0 or later.
- **Architecture**: Apple Silicon (arm64).
