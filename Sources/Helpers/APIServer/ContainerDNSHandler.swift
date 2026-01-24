//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ContainerAPIService
import DNS
import DNSServer

/// Handler that uses table lookup to resolve hostnames.
struct ContainerDNSHandler: DNSHandler {
    private let networkService: NetworksService
    private let ttl: UInt32

    public init(networkService: NetworksService, ttl: UInt32 = 5) {
        self.networkService = networkService
        self.ttl = ttl
    }

    public func answer(query: Message) async throws -> Message? {
        let question = query.questions[0]
        let records: [ResourceRecord]
        switch question.type {
        case ResourceRecordType.host:
            records = try await answerHost(question: question)
        case ResourceRecordType.host6:
            let result = try await answerHost6(question: question)
            if result.records.isEmpty && result.hostnameExists {
                // Return NODATA (noError with empty answers) when hostname exists but has no IPv6.
                // This is required because musl libc has issues when A record exists but AAAA returns NXDOMAIN.
                // musl treats NXDOMAIN on AAAA as "domain doesn't exist" and fails DNS resolution entirely.
                // NODATA correctly indicates "no IPv6 address available, but domain exists".
                return Message(
                    id: query.id,
                    type: .response,
                    returnCode: .noError,
                    questions: query.questions,
                    answers: []
                )
            }
            records = result.records
        case ResourceRecordType.nameServer,
            ResourceRecordType.alias,
            ResourceRecordType.startOfAuthority,
            ResourceRecordType.pointer,
            ResourceRecordType.mailExchange,
            ResourceRecordType.text,
            ResourceRecordType.service,
            ResourceRecordType.incrementalZoneTransfer,
            ResourceRecordType.standardZoneTransfer,
            ResourceRecordType.all:
            return Message(
                id: query.id,
                type: .response,
                returnCode: .notImplemented,
                questions: query.questions,
                answers: []
            )
        default:
            return Message(
                id: query.id,
                type: .response,
                returnCode: .formatError,
                questions: query.questions,
                answers: []
            )
        }

        if records.isEmpty {
            return nil
        }

        return Message(
            id: query.id,
            type: .response,
            returnCode: .noError,
            questions: query.questions,
            answers: records
        )
    }

    private func answerHost(question: Question) async throws -> [ResourceRecord] {
        let ipAllocations = try await networkService.lookup(hostname: question.name)
        if ipAllocations.isEmpty {
            return []
        }

        var records = [ResourceRecord]()
        for ipAllocation in ipAllocations {
            let ipv4 = ipAllocation.ipv4Address.address.description
            guard let ip = IPv4(ipv4) else {
                throw DNSResolverError.serverError("failed to parse IP address: \(ipv4)")
            }
            records.append(HostRecord<IPv4>(name: question.name, ttl: ttl, ip: ip))
        }

        return records
    }

    private func answerHost6(question: Question) async throws -> (records: [ResourceRecord], hostnameExists: Bool) {
        let ipAllocations = try await networkService.lookup(hostname: question.name)
        if ipAllocations.isEmpty {
            return ([], false)
        }

        var records = [ResourceRecord]()
        for ipAllocation in ipAllocations {
            guard let ipv6Address = ipAllocation.ipv6Address else {
                continue
            }
            let ipv6 = ipv6Address.address.description
            guard let ip = IPv6(ipv6) else {
                throw DNSResolverError.serverError("failed to parse IPv6 address: \(ipv6)")
            }
            records.append(HostRecord<IPv6>(name: question.name, ttl: ttl, ip: ip))
        }

        return (records, true)
    }
}
