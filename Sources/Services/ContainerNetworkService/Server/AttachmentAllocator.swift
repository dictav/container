//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerizationError
import ContainerizationExtras

actor AttachmentAllocator {
    private let allocator: any AddressAllocator<UInt32>
    private var hostnames: [String: Set<UInt32>] = [:]
    private var ipToNames: [UInt32: Set<String>] = [:]

    init(lower: UInt32, size: Int) throws {
        allocator = try UInt32.rotatingAllocator(
            lower: lower,
            size: UInt32(size)
        )
    }

    /// Allocate a network address for a host. The address will be registered for the hostname and all provided aliases.
    func allocate(hostname: String, aliases: [String] = []) async throws -> UInt32 {
        let index: UInt32
        // Client is responsible for ensuring two containers don't use same hostname, so provide existing IP if hostname exists
        if let existing = hostnames[hostname]?.first {
            index = existing
        } else {
            index = try allocator.allocate()
            hostnames[hostname, default: []].insert(index)
            ipToNames[index, default: []].insert(hostname)
        }

        for alias in aliases {
            hostnames[alias, default: []].insert(index)
            ipToNames[index, default: []].insert(alias)
        }

        return index
    }

    /// Free an allocated network address by hostname.
    @discardableResult
    func deallocate(hostname: String) async throws -> UInt32? {
        // Retrieve all indices associated with this hostname.
        guard let indices = hostnames[hostname], !indices.isEmpty else {
            return nil
        }

        // Preserve one representative index to return for compatibility.
        let representative = indices.first

        // Deallocate and clean up all indices associated with this hostname.
        for index in indices {
            if let names = ipToNames.removeValue(forKey: index) {
                for name in names {
                    hostnames[name]?.remove(index)
                    if hostnames[name]?.isEmpty == true {
                        hostnames.removeValue(forKey: name)
                    }
                }
            }

            try allocator.release(index)
        }

        return representative
    }

    /// If no addresses are allocated, prevent future allocations and return true.
    func disableAllocator() async -> Bool {
        allocator.disableAllocator()
    }

    /// Retrieve the allocator indices for a hostname or alias.
    func lookup(hostname: String) async throws -> [UInt32] {
        if let indices = hostnames[hostname] {
            return Array(indices)
        }
        return []
    }
}
