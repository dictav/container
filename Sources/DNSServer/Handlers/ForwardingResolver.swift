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

import DNS
import Foundation
import Logging
import NIOCore
import NIOPosix

/// A DNS handler that forwards queries to an upstream DNS server.
public struct ForwardingResolver: DNSHandler {
    private let nameservers: [String]
    private let log: Logger?

    public init(nameservers: [String], log: Logger? = nil) {
        self.nameservers = nameservers
        self.log = log
    }

    public func answer(query: Message) async throws -> Message? {
        guard !nameservers.isEmpty else {
            return nil
        }

        // Standard DNS only has one question usually, but we'll take the first one
        // consistent with how other handlers seem to operate in this codebase.
        guard let question = query.questions.first else {
            return nil
        }

        self.log?.debug("forwarding DNS query", metadata: ["name": "\(question.name)", "type": "\(question.type)"])

        let queryData = try query.serialize()

        for nameserver in nameservers {
            do {
                let address = try SocketAddress(ipAddress: nameserver, port: 53)
                let responseData = try await self.sendUDPQuery(queryData, to: address)
                let response = try Message(deserialize: responseData)
                
                self.log?.debug("received DNS response from upstream", metadata: ["nameserver": "\(nameserver)", "code": "\(response.returnCode)"])
                return response
            } catch {
                self.log?.warning("failed to forward DNS query to nameserver", metadata: ["nameserver": "\(nameserver)", "error": "\(error)"])
                continue
            }
        }

        return nil
    }

    private func sendUDPQuery(_ data: Data, to address: SocketAddress) async throws -> Data {
        let channel = try await DatagramBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "0.0.0.0", port: 0)
            .get()

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let asyncChannel = try NIOAsyncChannel(
                    wrappingChannelSynchronously: channel,
                    configuration: NIOAsyncChannel.Configuration(
                        inboundType: AddressedEnvelope<ByteBuffer>.self,
                        outboundType: AddressedEnvelope<ByteBuffer>.self
                    )
                )

                return try await asyncChannel.executeThenClose { inboundStream, outboundWriter in
                    let envelope = AddressedEnvelope(remoteAddress: address, data: ByteBuffer(bytes: data))
                    try await outboundWriter.write(envelope)

                    for try await response in inboundStream {
                        var buffer = response.data
                        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                            return Data(bytes)
                        }
                    }
                    throw DNSResolverError.serverError("No response from \(address)")
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                throw DNSResolverError.serverError("Timeout querying \(address)")
            }

            guard let result = try await group.next() else {
                throw DNSResolverError.serverError("Failed to receive response from \(address)")
            }
            group.cancelAll()
            return result
        }
    }
}
