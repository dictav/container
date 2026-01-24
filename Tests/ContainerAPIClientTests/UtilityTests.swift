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

import ContainerPersistence
import ContainerResource
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIClient

struct UtilityTests {

    @Test("Parse simple key-value pairs")
    func testSimpleKeyValuePairs() {
        let result = Utility.parseKeyValuePairs(["key1=value1", "key2=value2"])

        #expect(result["key1"] == "value1")
        #expect(result["key2"] == "value2")
    }

    @Test("Parse standalone keys")
    func testStandaloneKeys() {
        let result = Utility.parseKeyValuePairs(["standalone"])

        #expect(result["standalone"] == "")
    }

    @Test("Parse empty input")
    func testEmptyInput() {
        let result = Utility.parseKeyValuePairs([])

        #expect(result.isEmpty)
    }

    @Test("Parse mixed format")
    func testMixedFormat() {
        let result = Utility.parseKeyValuePairs(["key1=value1", "standalone", "key2=value2"])

        #expect(result["key1"] == "value1")
        #expect(result["standalone"] == "")
        #expect(result["key2"] == "value2")
    }

    @Test("Valid MAC address with colons")
    func testValidMACAddressWithColons() throws {
        try Utility.validMACAddress("02:42:ac:11:00:02")
        try Utility.validMACAddress("AA:BB:CC:DD:EE:FF")
        try Utility.validMACAddress("00:00:00:00:00:00")
        try Utility.validMACAddress("ff:ff:ff:ff:ff:ff")
    }

    @Test("Valid MAC address with hyphens")
    func testValidMACAddressWithHyphens() throws {
        try Utility.validMACAddress("02-42-ac-11-00-02")
        try Utility.validMACAddress("AA-BB-CC-DD-EE-FF")
    }

    @Test("Invalid MAC address format")
    func testInvalidMACAddressFormat() {
        #expect(throws: Error.self) {
            try Utility.validMACAddress("invalid")
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02:42:ac:11:00")  // Too short
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02:42:ac:11:00:02:03")  // Too long
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("ZZ:ZZ:ZZ:ZZ:ZZ:ZZ")  // Invalid hex
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02:42:ac:11:00:")  // Incomplete
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02.42.ac.11.00.02")  // Wrong separator
        }
    }

    @Test
    func testPublishPortParser() throws {
        let ports = try Parser.publishPorts([
            "127.0.0.1:8000:9080",
            "8080-8179:9000-9099/udp",
        ])
        #expect(ports.count == 2)
        #expect(ports[0].hostAddress.description == "127.0.0.1")
        #expect(ports[0].hostPort == 8000)
        #expect(ports[0].containerPort == 9080)
        #expect(ports[0].proto == .tcp)
        #expect(ports[0].count == 1)
        #expect(ports[1].hostAddress.description == "0.0.0.0")
        #expect(ports[1].hostPort == 8080)
        #expect(ports[1].containerPort == 9000)
        #expect(ports[1].proto == .udp)
        #expect(ports[1].count == 100)
    }

    @Test("Hierarchical DNS registration")
    func testGetAttachmentConfigurationsHierarchical() throws {
        // Mock default domain
        let originalDomain = DefaultsStore.getOptional(key: .defaultDNSDomain)
        DefaultsStore.set(value: "container", key: .defaultDNSDomain)
        defer {
            if let original = originalDomain {
                DefaultsStore.set(value: original, key: .defaultDNSDomain)
            } else {
                DefaultsStore.unset(key: .defaultDNSDomain)
            }
        }

        // Test default network (legacy behavior)
        let defaultNet = try Utility.getAttachmentConfigurations(
            containerId: "con1",
            networks: [Parser.ParsedNetwork(name: "default", macAddress: nil)],
            aliases: []
        )
        #expect(defaultNet.count == 1)
        #expect(defaultNet[0].network == "default")
        #expect(defaultNet[0].options.hostname == "con1.container.")

        // Test custom network (hierarchical behavior)
        let customNet = try Utility.getAttachmentConfigurations(
            containerId: "con1",
            networks: [Parser.ParsedNetwork(name: "mynet", macAddress: nil)],
            aliases: []
        )
        #expect(customNet.count == 1)
        #expect(customNet[0].network == "mynet")
        #expect(customNet[0].options.hostname == "con1.mynet.container.")

        // Test multiple networks
        let multiNet = try Utility.getAttachmentConfigurations(
            containerId: "con1",
            networks: [
                Parser.ParsedNetwork(name: "default", macAddress: nil),
                Parser.ParsedNetwork(name: "mynet", macAddress: nil),
            ],
            aliases: []
        )
        #expect(multiNet.count == 2)
        #expect(multiNet[0].options.hostname == "con1.container.")
        #expect(multiNet[1].options.hostname == "con1.mynet.container.")

        // Test fully-qualified container ID (preserved)
        let fqdnNet = try Utility.getAttachmentConfigurations(
            containerId: "con1.custom.domain",
            networks: [Parser.ParsedNetwork(name: "mynet", macAddress: nil)],
            aliases: []
        )
        #expect(fqdnNet[0].options.hostname == "con1.custom.domain.")
    }

    @Test("Hierarchical DNS registration without base domain")
    func testGetAttachmentConfigurationsNoBaseDomain() throws {
        let originalDomain = DefaultsStore.getOptional(key: .defaultDNSDomain)
        DefaultsStore.unset(key: .defaultDNSDomain)
        defer {
            if let original = originalDomain {
                DefaultsStore.set(value: original, key: .defaultDNSDomain)
            }
        }

        let result = try Utility.getAttachmentConfigurations(
            containerId: "con1",
            networks: [Parser.ParsedNetwork(name: "mynet", macAddress: nil)],
            aliases: []
        )
        #expect(result[0].options.hostname == "con1")
    }

    @Test("Network alias FQDN generation")
    func testGetAttachmentConfigurationsAliases() throws {
        // Mock default domain
        let originalDomain = DefaultsStore.getOptional(key: .defaultDNSDomain)
        DefaultsStore.set(value: "container", key: .defaultDNSDomain)
        defer {
            if let original = originalDomain {
                DefaultsStore.set(value: original, key: .defaultDNSDomain)
            } else {
                DefaultsStore.unset(key: .defaultDNSDomain)
            }
        }

        let result = try Utility.getAttachmentConfigurations(
            containerId: "con1",
            networks: [Parser.ParsedNetwork(name: "mynet", macAddress: nil)],
            aliases: ["web", "db.custom.", "api.extra"]
        )
        #expect(result.count == 1)
        let options = result[0].options
        #expect(options.aliases.count == 3)
        #expect(options.aliases.contains("web.mynet.container."))
        #expect(options.aliases.contains("db.custom."))
        #expect(options.aliases.contains("api.extra."))
    }
}
