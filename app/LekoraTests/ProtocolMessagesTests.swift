import XCTest
@testable import Lekora

final class ProtocolMessagesTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func testPairRequestSerialization() throws {
        let reqData = PairRequestData(
            pairing_token: "tok_test_123",
            device_name: "Test iPhone",
            client_version: "1.0.0",
            supported_proto_versions: [1]
        )
        let envelope = Envelope(
            type: "pair.request",
            instance_id: "inst_test_01",
            data: reqData
        )

        let encoded = try encoder.encode(envelope)
        let decoded = try decoder.decode(Envelope<PairRequestData>.self, from: encoded)

        XCTAssertEqual(decoded.v, 1)
        XCTAssertEqual(decoded.type, "pair.request")
        XCTAssertEqual(decoded.instance_id, "inst_test_01")
        XCTAssertNil(decoded.profile_id)
        XCTAssertEqual(decoded.data.pairing_token, "tok_test_123")
        XCTAssertEqual(decoded.data.device_name, "Test iPhone")
    }

    func testPairResponseSerialization() throws {
        let json = """
        {
          "v": 1,
          "id": "c1f7a29e-4e3a-4a2e-9d2a-8b1e0f3a4b5c",
          "type": "pair.response",
          "instance_id": "inst_01j9a8b7c6d5e4f3",
          "ts": "2026-11-07T20:55:01Z",
          "data": {
            "status": "ok",
            "proto_version": 1,
            "device_id": "dev_7a8b9c0d",
            "device_token": "sec_99a8b7c6d5e4f3a2b1c0d8e7f6a5b4c3",
            "instance_name": "Home Server",
            "endpoints": [
              "ws://192.168.1.120:49152",
              "ws://hermes-host.tailnet01.ts.net:49152"
            ]
          }
        }
        """.data(using: .utf8)!

        let envelope = try decoder.decode(Envelope<PairResponseData>.self, from: json)
        XCTAssertEqual(envelope.type, "pair.response")
        XCTAssertEqual(envelope.data.status, "ok")
        XCTAssertEqual(envelope.data.device_id, "dev_7a8b9c0d")
        XCTAssertEqual(envelope.data.endpoints.count, 2)
    }

    func testHelloAckSerializationWithProfileEquality() throws {
        let json = """
        {
          "v": 1,
          "id": "f8a7b6c5-1d2e-3f4a-5b6c-7d8e9f0a1b2c",
          "type": "hello.ack",
          "instance_id": "inst_01j9a8b7c6d5e4f3",
          "ts": "2026-11-07T21:00:01Z",
          "data": {
            "status": "ok",
            "current_seq": 105,
            "instance_name": "Home Server",
            "profiles": [
              {
                "profile_id": "assistant",
                "name": "Hermes Assistant",
                "avatar": "sparkles"
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let envelope = try decoder.decode(Envelope<HelloAckData>.self, from: json)
        XCTAssertEqual(envelope.data.status, "ok")
        XCTAssertEqual(envelope.data.current_seq, 105)
        XCTAssertEqual(envelope.data.profiles.first?.profile_id, "assistant")
        XCTAssertNotEqual(envelope.data.profiles.first?.profile_id, "main", "AGENTS.md Rule 5: No privileged 'main' profile.")
    }

    func testChatSendAndMessageSerialization() throws {
        let sendEnvelope = Envelope(
            type: "chat.send",
            instance_id: "inst_01",
            profile_id: "assistant",
            data: ChatSendData(text: "Ping")
        )
        let encodedSend = try encoder.encode(sendEnvelope)
        let decodedSend = try decoder.decode(Envelope<ChatSendData>.self, from: encodedSend)
        XCTAssertEqual(decodedSend.data.text, "Ping")
        XCTAssertEqual(decodedSend.profile_id, "assistant")

        let msgJson = """
        {
          "v": 1,
          "id": "e5f6a7b8-c9d0-1e2f-3a4b-5c6d7e8f9a0b",
          "type": "chat.message",
          "instance_id": "inst_01",
          "profile_id": "assistant",
          "ts": "2026-11-07T21:05:01Z",
          "data": {
            "seq": 106,
            "role": "assistant",
            "text": "Pong from Hermes"
          }
        }
        """.data(using: .utf8)!
        let decodedMsg = try decoder.decode(Envelope<ChatMessageData>.self, from: msgJson)
        XCTAssertEqual(decodedMsg.data.seq, 106)
        XCTAssertEqual(decodedMsg.data.role, "assistant")
        XCTAssertEqual(decodedMsg.data.text, "Pong from Hermes")
    }

    func testErrorEnvelopeSerialization() throws {
        let errJson = """
        {
          "v": 1,
          "id": "d0e1f2a3-b4c5-6d7e-8f9a-0b1c2d3e4f5a",
          "type": "error",
          "instance_id": "inst_01",
          "ts": "2026-11-07T21:00:01Z",
          "data": {
            "code": "AUTH_FAILED",
            "reason": "Invalid or revoked device token",
            "recoverable": false
          }
        }
        """.data(using: .utf8)!
        let decodedErr = try decoder.decode(Envelope<ErrorData>.self, from: errJson)
        XCTAssertEqual(decodedErr.data.code, "AUTH_FAILED")
        XCTAssertEqual(decodedErr.data.reason, "Invalid or revoked device token")
        XCTAssertEqual(decodedErr.data.recoverable, false)
    }
}
