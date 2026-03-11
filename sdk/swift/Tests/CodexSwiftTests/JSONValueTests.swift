import Foundation
import Testing
@testable import CodexSwift

struct JSONValueTests {
    @Test
    func roundTripsNestedJSONValues() throws {
        let value: JSONValue = .object([
            "name": .string("codex"),
            "count": .int(3),
            "pi": .double(3.14),
            "enabled": .bool(true),
            "nested": .object([
                "items": .array([.string("a"), .string("b")]),
                "nothing": .null,
            ]),
        ])

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded == value)
    }

    @Test
    func encodesThreadOptions() throws {
        let sandbox = SandboxPolicy.workspaceWrite(networkAccess: true, writableRoots: ["/tmp/work"])
        let value = try JSONValue.encoded(sandbox)
        let object = try #require(value.objectValue)

        #expect(object["type"] == .string("workspaceWrite"))
        #expect(object["networkAccess"] == .bool(true))
        #expect(object["writableRoots"] == .array([.string("/tmp/work")]))
    }
}
