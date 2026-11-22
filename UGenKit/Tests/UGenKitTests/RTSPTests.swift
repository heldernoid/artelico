import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import Network
import VideoToolbox
import XCTest
@testable import StudioCore
@testable import UGenKit

final class RTSPTests: XCTestCase {

    // MARK: SDP

    private let spsBase64 = "Z0IAKeKQFAe2AtwEBAaQeJEV"
    private let ppsBase64 = "aM48gA=="

    func testSDPWithParameterSetsAndRelativeControl() throws {
        // The shape Hikvision cameras send.
        let text = """
        v=0\r
        o=- 1700000000000000 1700000000000000 IN IP4 192.168.1.64\r
        s=Media Presentation\r
        e=NONE\r
        b=AS:5100\r
        t=0 0\r
        a=control:rtsp://192.168.1.64:554/Streaming/Channels/101/\r
        m=video 0 RTP/AVP 96\r
        c=IN IP4 0.0.0.0\r
        b=AS:5000\r
        a=recvonly\r
        a=x-dimensions:1920,1080\r
        a=control:rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1\r
        a=rtpmap:96 H264/90000\r
        a=fmtp:96 profile-level-id=420029; packetization-mode=1; sprop-parameter-sets=\(spsBase64),\(ppsBase64)\r
        m=audio 0 RTP/AVP 8\r
        a=control:rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=2\r
        a=rtpmap:8 PCMA/8000\r
        """
        let sdp = RTSPSDP.parse(text)
        XCTAssertEqual(sdp.sessionControl, "rtsp://192.168.1.64:554/Streaming/Channels/101/")
        XCTAssertEqual(sdp.media.count, 2)
        let track = try XCTUnwrap(sdp.h264Track())
        XCTAssertEqual(track.payloadType, 96)
        XCTAssertEqual(track.clockRate, 90000)
        XCTAssertEqual(track.packetizationMode, 1)
        XCTAssertEqual(track.control, "rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1")
        XCTAssertEqual(track.sps, Data(base64Encoded: spsBase64))
        XCTAssertEqual(track.pps, Data(base64Encoded: ppsBase64))
        XCTAssertEqual(track.sps?.first, 0x67)
        XCTAssertEqual(track.pps?.first, 0x68)
        XCTAssertEqual(track.parameterSets.count, 2)
        // An absolute control address is used as it is.
        XCTAssertEqual(RTSPSDP.resolve(control: track.control, base: "rtsp://192.168.1.64:554/other/"),
                       "rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1")
    }

    func testSDPAudioFirstNoParameterSetsStarControl() throws {
        // live555-style: session control "*", relative track names, Unix line endings, audio before video.
        let text = """
        v=0
        o=- 12345 1 IN IP4 10.0.0.5
        s=Session streamed by "testOnDemandRTSPServer"
        t=0 0
        a=tool:LIVE555 Streaming Media v2023.01.19
        a=type:broadcast
        a=control:*
        a=range:npt=0-
        m=audio 0 RTP/AVP 0
        c=IN IP4 0.0.0.0
        a=control:track1
        m=video 0 RTP/AVP 97
        c=IN IP4 0.0.0.0
        b=AS:500
        a=rtpmap:97 H264/90000
        a=fmtp:97 packetization-mode=1;profile-level-id=64001F
        a=control:track2
        """
        let sdp = RTSPSDP.parse(text)
        XCTAssertEqual(sdp.sessionControl, "*")
        let track = try XCTUnwrap(sdp.h264Track())
        XCTAssertEqual(track.payloadType, 97)
        XCTAssertEqual(track.control, "track2")
        XCTAssertNil(track.sps)
        XCTAssertNil(track.pps)
        XCTAssertTrue(track.parameterSets.isEmpty)
        XCTAssertEqual(RTSPSDP.resolve(control: track.control, base: "rtsp://10.0.0.5:8554/cam/"), "rtsp://10.0.0.5:8554/cam/track2")
        XCTAssertEqual(RTSPSDP.resolve(control: track.control, base: "rtsp://10.0.0.5:8554/cam"), "rtsp://10.0.0.5:8554/cam/track2")
        XCTAssertEqual(RTSPSDP.resolve(control: sdp.sessionControl, base: "rtsp://10.0.0.5:8554/cam/"), "rtsp://10.0.0.5:8554/cam/")
        XCTAssertEqual(RTSPSDP.resolve(control: nil, base: "rtsp://10.0.0.5:8554/cam"), "rtsp://10.0.0.5:8554/cam")
        XCTAssertEqual(RTSPSDP.resolve(control: "/abs/track2", base: "rtsp://10.0.0.5:8554/cam/"), "rtsp://10.0.0.5:8554/abs/track2")
    }

    func testSDPMultipleVideoTracksPicksH264() throws {
        let text = """
        v=0\r
        o=- 0 0 IN IP4 127.0.0.1\r
        s=Multi\r
        t=0 0\r
        m=video 0 RTP/AVP 26\r
        a=control:mjpeg\r
        m=video 0 RTP/AVP 98\r
        a=rtpmap:98 H265/90000\r
        a=fmtp:98 sprop-vps=QAEMAf//AWAAAAMAAAMAAAMAAAMAlqwJ; sprop-sps=QgEBAWAAAAMAAAMAAAMAAAMAlqADwIAQ5Y2uSTJK\r
        a=control:trackID=0\r
        m=video 0 RTP/AVP 99 96\r
        a=rtpmap:99 rtx/90000\r
        a=rtpmap:96 h264/90000\r
        a=fmtp:96 packetization-mode=1;sprop-parameter-sets=\(spsBase64.replacingOccurrences(of: "=", with: "")),\(ppsBase64.replacingOccurrences(of: "=", with: ""))\r
        a=control:trackID=1\r
        m=application 0 RTP/AVP 107\r
        a=rtpmap:107 vnd.onvif.metadata/90000\r
        a=control:trackID=2\r
        """
        let sdp = RTSPSDP.parse(text)
        XCTAssertEqual(sdp.videoCodecs, ["JPEG", "H265", "RTX", "H264"])
        let track = try XCTUnwrap(sdp.h264Track())
        XCTAssertEqual(track.payloadType, 96)
        XCTAssertEqual(track.control, "trackID=1")
        // Base64 without padding must still decode.
        XCTAssertEqual(track.sps, Data(base64Encoded: spsBase64))
        XCTAssertEqual(track.pps, Data(base64Encoded: ppsBase64))
    }

    func testSDPWithOnlyH265HasNoH264Track() {
        let text = "v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H265/90000\r\na=control:trackID=0\r\nm=audio 0 RTP/AVP 97\r\na=rtpmap:97 MPEG4-GENERIC/16000\r\n"
        let sdp = RTSPSDP.parse(text)
        XCTAssertNil(sdp.h264Track())
        XCTAssertEqual(sdp.videoCodecs, ["H265"])
    }

    // MARK: Authentication

    func testBasicHeader() {
        // RFC 2617 section 2.
        XCTAssertEqual(RTSPAuth.basicHeader(user: "Aladdin", password: "open sesame"), "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==")
    }

    func testDigestResponseRFC2617() {
        let nonce = "dcd98b7102dd2f0e8b11d0f600bfb0c093"
        // The example in RFC 2617 section 3.5 (qop=auth). The expected value is printed in the RFC.
        XCTAssertEqual(RTSPAuth.digestResponse(user: "Mufasa", password: "Circle Of Life", realm: "testrealm@host.com", nonce: nonce,
                                               method: "GET", uri: "/dir/index.html", qop: "auth", nonceCount: "00000001", cnonce: "0a4f113b"),
                       "6629fae49393a05397450978507c4ef1")
        // Same inputs without qop; expected values computed separately with the md5 command-line tool.
        XCTAssertEqual(RTSPAuth.digestResponse(user: "Mufasa", password: "Circle Of Life", realm: "testrealm@host.com", nonce: nonce,
                                               method: "GET", uri: "/dir/index.html"),
                       "670fd8c2df070c60b045671b8b24ff02")
        // An RTSP request line.
        XCTAssertEqual(RTSPAuth.digestResponse(user: "Mufasa", password: "Circle Of Life", realm: "testrealm@host.com", nonce: nonce,
                                               method: "DESCRIBE", uri: "rtsp://192.168.1.10:554/stream1"),
                       "462e9a168c2027e8fd03d63ae9e7c72b")
        XCTAssertEqual(RTSPAuth.digestResponse(user: "Mufasa", password: "Circle Of Life", realm: "testrealm@host.com", nonce: nonce,
                                               method: "DESCRIBE", uri: "rtsp://192.168.1.10:554/stream1", qop: "auth",
                                               nonceCount: "00000002", cnonce: "0a4f113b"),
                       "e2c37975c76dad2eee3e595529a1b3d2")
        // The SHA-256 example of RFC 7616 section 3.9.1.
        XCTAssertEqual(RTSPAuth.digestResponse(user: "Mufasa", password: "Circle of Life", realm: "http-auth@example.org",
                                               nonce: "7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v", method: "GET", uri: "/dir/index.html",
                                               qop: "auth", nonceCount: "00000001", cnonce: "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ",
                                               algorithm: "SHA-256"),
                       "753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1")
    }

    func testDigestHeaderAndChallengeParsing() throws {
        let header = #"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#
        let challenge = try XCTUnwrap(RTSPAuth.parseChallenge(header))
        XCTAssertEqual(challenge.scheme, .digest)
        XCTAssertEqual(challenge.realm, "testrealm@host.com")
        XCTAssertEqual(challenge.nonce, "dcd98b7102dd2f0e8b11d0f600bfb0c093")
        XCTAssertEqual(challenge.opaque, "5ccc069c403ebaf9f0171e9517f40e41")
        XCTAssertEqual(challenge.qop, ["auth", "auth-int"])
        XCTAssertFalse(challenge.stale)
        let answer = RTSPAuth.digestHeader(challenge: challenge, user: "Mufasa", password: "Circle Of Life", method: "GET",
                                           uri: "/dir/index.html", nonceCount: 1, cnonce: "0a4f113b")
        XCTAssertEqual(answer, #"Digest username="Mufasa", realm="testrealm@host.com", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", uri="/dir/index.html", response="6629fae49393a05397450978507c4ef1", opaque="5ccc069c403ebaf9f0171e9517f40e41", qop=auth, nc=00000001, cnonce="0a4f113b""#)

        // Without qop, as most cameras send it.
        let plain = try XCTUnwrap(RTSPAuth.parseChallenge(#"Digest realm="testrealm@host.com", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", stale="TRUE""#))
        XCTAssertTrue(plain.qop.isEmpty)
        XCTAssertTrue(plain.stale)
        let plainAnswer = RTSPAuth.digestHeader(challenge: plain, user: "Mufasa", password: "Circle Of Life", method: "GET",
                                                uri: "/dir/index.html", nonceCount: 1, cnonce: "ignored")
        XCTAssertEqual(plainAnswer, #"Digest username="Mufasa", realm="testrealm@host.com", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", uri="/dir/index.html", response="670fd8c2df070c60b045671b8b24ff02""#)

        // Several offers: Digest wins over Basic, whatever the order.
        let chosen = try XCTUnwrap(RTSPAuth.choose([#"Basic realm="cam""#, #"Digest realm="cam", nonce="abc", algorithm=MD5"#]))
        XCTAssertEqual(chosen.scheme, .digest)
        XCTAssertEqual(chosen.algorithm, "MD5")
        XCTAssertEqual(RTSPAuth.choose([#"Basic realm="a, b""#])?.realm, "a, b")
        XCTAssertNil(RTSPAuth.choose(["Negotiate"]))
    }

    // MARK: Interleaved framing

    private func frame(channel: UInt8, _ payload: [UInt8]) -> Data {
        Data([0x24, channel, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload)
    }

    private func summarize(_ items: [RTSPStreamParser.Item]) -> [String] {
        items.map { item in
            switch item {
            case .interleaved(let channel, let payload): return "rtp \(channel) \(payload.map { String(format: "%02x", $0) }.joined())"
            case .response(let response):
                return "response \(response.status) \(response.reason) cseq=\(response.cseq ?? -1) body=\(String(decoding: response.body, as: UTF8.self))"
            case .request(let method): return "request \(method)"
            }
        }
    }

    func testInterleavedParsingAcrossChunkBoundaries() {
        var stream = Data()
        stream.append(Data("RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Type: application/sdp\r\nContent-Length: 11\r\n\r\nv=0\r\ns=$x\r\n".utf8))
        stream.append(frame(channel: 0, [0x80, 0x60, 1, 2, 3]))
        // A payload that looks like framing and like a response must be passed through untouched.
        stream.append(frame(channel: 0, Array("$\u{0}\u{0}\u{4}RTSP/1.0 500 No\r\n\r\n".utf8)))
        stream.append(frame(channel: 1, []))
        stream.append(Data("RTSP/1.0 200 OK\r\ncseq: 7\r\nSession: 66334873;timeout=60\r\n\r\n".utf8))
        stream.append(frame(channel: 0, [UInt8](repeating: 0xAB, count: 300)))
        stream.append(Data("OPTIONS rtsp://a/b RTSP/1.0\r\nCSeq: 1\r\n\r\n".utf8))
        stream.append(Data("RTSP/1.0 454 Session Not Found\r\nCSeq: 8\r\n\r\n".utf8))
        stream.append(frame(channel: 2, [9, 8, 7]))

        var whole = RTSPStreamParser()
        let expected = summarize(whole.append(stream))
        XCTAssertEqual(expected.count, 9)
        XCTAssertEqual(expected[0], "response 200 OK cseq=2 body=v=0\r\ns=$x\r\n")
        XCTAssertEqual(expected[1], "rtp 0 8060010203")
        XCTAssertTrue(expected[2].hasPrefix("rtp 0 24000004525453502f"))
        XCTAssertEqual(expected[3], "rtp 1 ")
        XCTAssertEqual(expected[4], "response 200 OK cseq=7 body=")
        XCTAssertEqual(expected[6], "request OPTIONS")
        XCTAssertEqual(expected[7], "response 454 Session Not Found cseq=8 body=")
        XCTAssertEqual(expected[8], "rtp 2 090807")
        XCTAssertEqual(whole.skippedBytes, 0)

        for chunkSize in [1, 2, 3, 5, 7, 13, 64, 257] {
            var parser = RTSPStreamParser()
            var items: [RTSPStreamParser.Item] = []
            var offset = 0
            while offset < stream.count {
                let end = min(stream.count, offset + chunkSize)
                items += parser.append(stream.subdata(in: offset..<end))
                offset = end
            }
            XCTAssertEqual(summarize(items), expected, "chunk size \(chunkSize)")
            XCTAssertEqual(parser.skippedBytes, 0)
        }

        // Pseudo-random chunk sizes.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            var parser = RTSPStreamParser()
            var items: [RTSPStreamParser.Item] = []
            var offset = 0
            while offset < stream.count {
                let end = min(stream.count, offset + Int.random(in: 1...90, using: &generator))
                items += parser.append(stream.subdata(in: offset..<end))
                offset = end
            }
            XCTAssertEqual(summarize(items), expected)
        }
    }

    func testInterleavedParsingRecoversFromGarbage() {
        var parser = RTSPStreamParser()
        var stream = Data([0x00, 0xFF, 0x7A, 0x7A])
        stream.append(frame(channel: 0, [1, 2]))
        stream.append(Data("HELLO WORLD\r\n".utf8))
        stream.append(Data("RTSP/1.0 200 OK\r\nCSeq: 3\r\n\r\n".utf8))
        let items = summarize(parser.append(stream))
        XCTAssertEqual(items, ["rtp 0 0102", "response 200 OK cseq=3 body="])
        XCTAssertGreaterThan(parser.skippedBytes, 0)
    }

    // MARK: RTP depacketization

    private func rtp(sequence: UInt16, timestamp: UInt32, marker: Bool = false, payloadType: UInt8 = 96, payload: [UInt8],
                     extensionWords: Int? = nil, padding: Int = 0) -> Data {
        var first: UInt8 = 0x80
        if extensionWords != nil { first |= 0x10 }
        if padding > 0 { first |= 0x20 }
        var bytes: [UInt8] = [first, (marker ? 0x80 : 0) | payloadType, UInt8(sequence >> 8), UInt8(sequence & 0xFF),
                              UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xFF), UInt8((timestamp >> 8) & 0xFF), UInt8(timestamp & 0xFF),
                              0x11, 0x22, 0x33, 0x44]
        if let extensionWords {
            bytes += [0xBE, 0xDE, UInt8(extensionWords >> 8), UInt8(extensionWords & 0xFF)] + [UInt8](repeating: 0, count: extensionWords * 4)
        }
        bytes += payload
        if padding > 0 { bytes += [UInt8](repeating: 0, count: padding - 1) + [UInt8(padding)] }
        return Data(bytes)
    }

    func testDepacketizeSingleNALUnits() {
        var depacketizer = H264Depacketizer(payloadType: 96)
        XCTAssertTrue(depacketizer.push(rtp(sequence: 10, timestamp: 1000, payload: [0x67, 1, 2])).isEmpty)
        XCTAssertTrue(depacketizer.push(rtp(sequence: 11, timestamp: 1000, payload: [0x68, 3])).isEmpty)
        // Another payload type (for example audio on the same channel) is ignored and does not count as loss.
        XCTAssertTrue(depacketizer.push(rtp(sequence: 500, timestamp: 77, marker: true, payloadType: 0, payload: [1, 2, 3])).isEmpty)
        let units = depacketizer.push(rtp(sequence: 12, timestamp: 1000, marker: true, payload: [0x65, 4, 5, 6]))
        XCTAssertEqual(units, [H264AccessUnit(nals: [Data([0x67, 1, 2]), Data([0x68, 3]), Data([0x65, 4, 5, 6])], timestamp: 1000, damaged: false)])
        XCTAssertTrue(units[0].containsKeyframe)

        // No marker bit: the change of timestamp ends the unit. Header extension and padding are skipped.
        XCTAssertTrue(depacketizer.push(rtp(sequence: 13, timestamp: 4000, payload: [0x41, 7], extensionWords: 2, padding: 3)).isEmpty)
        let next = depacketizer.push(rtp(sequence: 14, timestamp: 7000, payload: [0x41, 8]))
        XCTAssertEqual(next, [H264AccessUnit(nals: [Data([0x41, 7])], timestamp: 4000, damaged: false)])
        XCTAssertFalse(next[0].containsKeyframe)
        XCTAssertEqual(depacketizer.lostPackets, 0)
    }

    func testDepacketizeSTAPA() {
        var depacketizer = H264Depacketizer()
        let stap: [UInt8] = [0x78, 0, 3, 0x67, 0xAA, 0xBB, 0, 2, 0x68, 0xCC]
        XCTAssertTrue(depacketizer.push(rtp(sequence: 1, timestamp: 90, payload: stap)).isEmpty)
        let units = depacketizer.push(rtp(sequence: 2, timestamp: 90, marker: true, payload: [0x65, 1]))
        XCTAssertEqual(units, [H264AccessUnit(nals: [Data([0x67, 0xAA, 0xBB]), Data([0x68, 0xCC]), Data([0x65, 1])], timestamp: 90, damaged: false)])

        // A length that runs past the end of the packet marks the unit as damaged.
        let broken = depacketizer.push(rtp(sequence: 3, timestamp: 180, marker: true, payload: [0x78, 0, 9, 0x67, 1]))
        XCTAssertEqual(broken.count, 1)
        XCTAssertTrue(broken[0].damaged)
    }

    func testDepacketizeFUA() {
        var depacketizer = H264Depacketizer()
        // NAL header 0x65 (nal_ref_idc 3, type 5) becomes indicator 0x7C and fragment header type 5.
        XCTAssertTrue(depacketizer.push(rtp(sequence: 65534, timestamp: 5, payload: [0x7C, 0x85, 1, 2])).isEmpty)
        XCTAssertTrue(depacketizer.push(rtp(sequence: 65535, timestamp: 5, payload: [0x7C, 0x05, 3, 4])).isEmpty)
        // The sequence number wraps around here.
        let units = depacketizer.push(rtp(sequence: 0, timestamp: 5, marker: true, payload: [0x7C, 0x45, 5]))
        XCTAssertEqual(units, [H264AccessUnit(nals: [Data([0x65, 1, 2, 3, 4, 5])], timestamp: 5, damaged: false)])
        XCTAssertEqual(depacketizer.lostPackets, 0)
    }

    func testDepacketizeFUAWithLostFragment() {
        var depacketizer = H264Depacketizer()
        XCTAssertTrue(depacketizer.push(rtp(sequence: 1, timestamp: 5, payload: [0x41, 9])).isEmpty)
        XCTAssertTrue(depacketizer.push(rtp(sequence: 2, timestamp: 5, payload: [0x7C, 0x81, 1, 2])).isEmpty)
        // Sequence 3 (a middle fragment) is lost.
        XCTAssertTrue(depacketizer.push(rtp(sequence: 4, timestamp: 5, payload: [0x7C, 0x01, 5, 6])).isEmpty)
        let units = depacketizer.push(rtp(sequence: 5, timestamp: 5, marker: true, payload: [0x7C, 0x41, 7]))
        // The incomplete NAL unit is not delivered, and the unit says that it is damaged.
        XCTAssertEqual(units, [H264AccessUnit(nals: [Data([0x41, 9])], timestamp: 5, damaged: true)])
        XCTAssertEqual(depacketizer.lostPackets, 1)

        // The next picture is complete again.
        XCTAssertTrue(depacketizer.push(rtp(sequence: 6, timestamp: 9, payload: [0x7C, 0x85, 1])).isEmpty)
        let good = depacketizer.push(rtp(sequence: 7, timestamp: 9, marker: true, payload: [0x7C, 0x45, 2]))
        XCTAssertEqual(good, [H264AccessUnit(nals: [Data([0x65, 1, 2])], timestamp: 9, damaged: false)])

        // Losing the last packet of a picture (with its marker) damages that picture and the next one,
        // whose first packets may be among the lost ones.
        XCTAssertTrue(depacketizer.push(rtp(sequence: 8, timestamp: 12, payload: [0x41, 1])).isEmpty)
        let afterLoss = depacketizer.push(rtp(sequence: 10, timestamp: 15, marker: true, payload: [0x41, 2]))
        XCTAssertEqual(afterLoss.map(\.damaged), [true, true])
        XCTAssertEqual(afterLoss.map(\.timestamp), [12, 15])
    }

    func testExpGolomb() {
        XCTAssertEqual(H264Decoder.readExpGolomb([0b1000_0000], bitOffset: 0), 0)
        XCTAssertEqual(H264Decoder.readExpGolomb([0b0100_0000], bitOffset: 0), 1)
        XCTAssertEqual(H264Decoder.readExpGolomb([0b0110_0000], bitOffset: 0), 2)
        XCTAssertEqual(H264Decoder.readExpGolomb([0xFF, 0b0010_0100], bitOffset: 8), 3)
        XCTAssertNil(H264Decoder.readExpGolomb([0], bitOffset: 0))
    }

    // MARK: Decoder alone

    func testDecoderWaitsForKeyframeAndDecodes() throws {
        let clip = try TestClip.shared.get()
        let decoder = H264Decoder()
        defer { decoder.invalidate() }
        let firstKey = try XCTUnwrap(clip.frames.firstIndex { $0.isKeyframe })
        let secondKey = try XCTUnwrap(clip.frames[(firstKey + 1)...].firstIndex { $0.isKeyframe })
        XCTAssertGreaterThan(secondKey - firstKey, 1)
        // A frame that is not a keyframe gives nothing, even with the parameter sets known.
        decoder.setParameterSet(clip.sps)
        decoder.setParameterSet(clip.pps)
        XCTAssertNil(decoder.decode(H264AccessUnit(nals: clip.frames[firstKey + 1].nals, timestamp: 0, damaged: false)))
        var decoded = 0
        for index in firstKey..<secondKey {
            if let image = decoder.decode(H264AccessUnit(nals: clip.frames[index].nals, timestamp: UInt32(index * 3000), damaged: false)) {
                decoded += 1
                XCTAssertEqual(image.width, TestClip.width)
                XCTAssertEqual(image.height, TestClip.height)
            }
        }
        XCTAssertEqual(decoded, secondKey - firstKey)
        XCTAssertEqual(decoder.dimensions?.width, TestClip.width)
        // A damaged unit makes the decoder wait for the next keyframe.
        XCTAssertNil(decoder.decode(H264AccessUnit(nals: [], timestamp: 0, damaged: true)))
        XCTAssertNil(decoder.decode(H264AccessUnit(nals: clip.frames[firstKey + 1].nals, timestamp: 0, damaged: false)))
        XCTAssertNotNil(decoder.decode(H264AccessUnit(nals: clip.frames[secondKey].nals, timestamp: 0, damaged: false)))
        // skipOutput decodes without making a picture.
        XCTAssertNil(decoder.decode(H264AccessUnit(nals: clip.frames[secondKey + 1].nals, timestamp: 0, damaged: false), skipOutput: true))
        XCTAssertNotNil(decoder.decode(H264AccessUnit(nals: clip.frames[secondKey + 2].nals, timestamp: 0, damaged: false)))
        XCTAssertEqual(decoder.lastErrorStatus, 0)
    }

    // MARK: Loopback integration

    /// Runs one complete session against the in-process server and checks the pictures.
    private func runLoopback(_ options: LoopbackRTSPServer.Options, credentials: String = "",
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let clip = try TestClip.shared.get()
        let server = LoopbackRTSPServer(clip: clip, options: options)
        let port = try server.start()
        defer { server.stop() }
        let client = RTSPClient(url: URL(string: "rtsp://\(credentials)127.0.0.1:\(port)/stream")!, timeout: 10)
        try await client.start()

        // Collect pictures until there are plenty and the client has sent at least one keep-alive.
        var images: [CGImage] = []
        let end = Date().addingTimeInterval(6)
        while Date() < end, images.count < 30 || server.stats.keepAlives < 1 {
            if let image = client.takeLatest() { images.append(image) }
            try await Task.sleep(for: .milliseconds(3))
        }
        XCTAssertGreaterThanOrEqual(images.count, 30, file: file, line: line)
        // Polled every 3 ms while frames come every 20 ms: a frame handed out twice would show up here.
        XCTAssertLessThanOrEqual(images.count, client.framesDecoded, "takeLatest must return each frame only once", file: file, line: line)
        print("RTSP loopback (\(options.auth)): \(images.count) pictures taken, \(client.framesDecoded) decoded, \(server.stats.framesSent) sent, " +
              "\(server.stats.fragmentPackets) FU-A packets, \(server.stats.keepAlives) keep-alives")
        XCTAssertGreaterThanOrEqual(client.framesDecoded, images.count, file: file, line: line)
        XCTAssertNil(client.failure, file: file, line: line)

        var positions = Set<Int>()
        for image in images {
            XCTAssertEqual(image.width, TestClip.width, file: file, line: line)
            XCTAssertEqual(image.height, TestClip.height, file: file, line: line)
            let pixels = try XCTUnwrap(Pixels(image))
            // Top left quarter is red, top right quarter is blue.
            let red = pixels[80, 60], blue = pixels[240, 60]
            XCTAssertTrue(red.r > 170 && red.g < 90 && red.b < 90, "expected red, got \(red)", file: file, line: line)
            XCTAssertTrue(blue.b > 170 && blue.r < 90 && blue.g < 90, "expected blue, got \(blue)", file: file, line: line)
            // The green square moves along the bottom half; find its centre.
            let greenColumns = (0..<TestClip.width).filter { x in
                let p = pixels[x, TestClip.squareY + TestClip.squareSize / 2]
                return p.g > 150 && p.r < 110 && p.b < 110
            }
            guard let first = greenColumns.first, let last = greenColumns.last else {
                XCTFail("no green square in the picture", file: file, line: line)
                continue
            }
            XCTAssertEqual(Double(last - first + 1), Double(TestClip.squareSize), accuracy: 6, file: file, line: line)
            // The square only ever sits at one of the positions that were encoded.
            let left = Double(first)
            let nearest = (0..<TestClip.frameCount).map { Double(TestClip.squareX(frame: $0)) }.min { abs($0 - left) < abs($1 - left) }!
            XCTAssertEqual(left, nearest, accuracy: 3, file: file, line: line)
            positions.insert(Int(nearest))
        }
        XCTAssertGreaterThanOrEqual(positions.count, 10, "the square should have been seen at many positions", file: file, line: line)

        let playing = server.stats
        XCTAssertGreaterThan(playing.fragmentPackets, 0, "the clip should need FU-A", file: file, line: line)
        XCTAssertGreaterThan(playing.aggregatePackets, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(playing.keepAlives, 1, file: file, line: line)
        XCTAssertEqual(playing.teardowns, 0, file: file, line: line)
        if options.auth != .none {
            XCTAssertGreaterThan(playing.unauthorized, 0, "the server should have asked for credentials", file: file, line: line)
            XCTAssertGreaterThanOrEqual(playing.authorized, 4, file: file, line: line)
        }

        // Frames keep coming after the keep-alive answer arrived between RTP packets.
        let before = client.framesDecoded
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(client.framesDecoded, before, file: file, line: line)

        client.stop()
        XCTAssertNil(client.takeLatest(), file: file, line: line)
        let closed = Date().addingTimeInterval(3)
        while Date() < closed, server.stats.teardowns < 1 || server.stats.openConnections > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(server.stats.teardowns, 1, "TEARDOWN should have been sent", file: file, line: line)
        XCTAssertEqual(server.stats.openConnections, 0, "the connection should be closed", file: file, line: line)
    }

    func testLoopbackStream() async throws {
        // Parameter sets only in the stream (STAP-A before every keyframe), not in the SDP.
        try await runLoopback(.init(auth: .none, parameterSetsInSDP: false))
    }

    func testLoopbackStreamWithDigest() async throws {
        try await runLoopback(.init(auth: .digest(qop: true), parameterSetsInSDP: true), credentials: "admin:s3cret%20pass@")
    }

    func testLoopbackStreamWithDigestWithoutQop() async throws {
        try await runLoopback(.init(auth: .digest(qop: false), parameterSetsInSDP: true), credentials: "admin:s3cret%20pass@")
    }

    func testLoopbackStreamWithBasic() async throws {
        try await runLoopback(.init(auth: .basic, parameterSetsInSDP: true), credentials: "admin:s3cret%20pass@")
    }

    /// Starts a client that is expected to fail and returns the message.
    private func startExpectingFailure(_ options: LoopbackRTSPServer.Options, credentials: String = "", path: String = "/stream",
                                       timeout: TimeInterval = 5) async throws -> String {
        let server = LoopbackRTSPServer(clip: try TestClip.shared.get(), options: options)
        let port = try server.start()
        defer { server.stop() }
        let client = RTSPClient(url: URL(string: "rtsp://\(credentials)127.0.0.1:\(port)\(path)")!, timeout: timeout)
        defer { client.stop() }
        do {
            try await client.start()
            XCTFail("start() should have failed")
            return ""
        } catch {
            XCTAssertTrue(error is RTSPError)
            XCTAssertNil(client.takeLatest())
            return error.localizedDescription
        }
    }

    func testLoopbackErrors() async throws {
        let wrongPassword = try await startExpectingFailure(.init(auth: .digest(qop: true)), credentials: "admin:wrong@")
        XCTAssertTrue(wrongPassword.contains("rejected the user name or password"), wrongPassword)

        let wrongBasic = try await startExpectingFailure(.init(auth: .basic), credentials: "admin:wrong@")
        XCTAssertTrue(wrongBasic.contains("rejected the user name or password"), wrongBasic)

        let noCredentials = try await startExpectingFailure(.init(auth: .digest(qop: false)))
        XCTAssertTrue(noCredentials.contains("asks for a user name and password"), noCredentials)

        let notFound = try await startExpectingFailure(.init(), path: "/nothing")
        XCTAssertTrue(notFound.contains("404"), notFound)

        let udpOnly = try await startExpectingFailure(.init(rejectInterleaved: true))
        XCTAssertTrue(udpOnly.contains("only offers UDP"), udpOnly)

        let hevc = try await startExpectingFailure(.init(hevcOnly: true))
        XCTAssertTrue(hevc.contains("H.265"), hevc)

        let silent = try await startExpectingFailure(.init(sendNoVideo: true), timeout: 1)
        XCTAssertTrue(silent.contains("sent no video data"), silent)
    }

    func testConnectionRefused() async throws {
        // A port on which nothing listens: take one from a listener and close it again.
        let server = LoopbackRTSPServer(clip: try TestClip.shared.get(), options: .init())
        let port = try server.start()
        server.stop()
        try await Task.sleep(for: .milliseconds(200))
        let client = RTSPClient(url: URL(string: "rtsp://127.0.0.1:\(port)/stream")!, timeout: 5)
        do {
            try await client.start()
            XCTFail("start() should have failed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Could not connect to 127.0.0.1:\(port)"), error.localizedDescription)
        }
    }

    func testFailureIsReportedWhenTheStreamEnds() async throws {
        let server = LoopbackRTSPServer(clip: try TestClip.shared.get(), options: .init(closeAfterFrames: 40))
        let port = try server.start()
        defer { server.stop() }
        let client = RTSPClient(url: URL(string: "rtsp://127.0.0.1:\(port)/stream")!, timeout: 10)
        try await client.start()
        let end = Date().addingTimeInterval(5)
        while Date() < end, client.failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(client.failure, "The camera closed the connection.")
        client.stop()
        XCTAssertNil(client.failure)
    }

    func testStopDuringStartAndRestart() async throws {
        let server = LoopbackRTSPServer(clip: try TestClip.shared.get(), options: .init(sendNoVideo: true))
        let port = try server.start()
        defer { server.stop() }
        let client = RTSPClient(url: URL(string: "rtsp://127.0.0.1:\(port)/stream")!, timeout: 10)
        let stopper = Task {
            try await Task.sleep(for: .milliseconds(300))
            client.stop()
        }
        do {
            try await client.start()
            XCTFail("start() should have failed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stopped"), error.localizedDescription)
        }
        try await stopper.value
        let closed = Date().addingTimeInterval(3)
        while Date() < closed, server.stats.openConnections > 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(server.stats.openConnections, 0)

        // The same client object can be started again (here against a server that does send video).
        let working = LoopbackRTSPServer(clip: try TestClip.shared.get(), options: .init())
        let workingPort = try working.start()
        defer { working.stop() }
        let second = RTSPClient(url: URL(string: "rtsp://127.0.0.1:\(workingPort)/stream")!, timeout: 10)
        try await second.start()
        second.stop()
        try await second.start()
        let end = Date().addingTimeInterval(3)
        var image: CGImage?
        while Date() < end, image == nil {
            image = second.takeLatest()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(image)
        second.stop()
    }

    // MARK: Live

    func testLiveStream() async throws {
        guard let address = ProcessInfo.processInfo.environment["UGEN_RTSP_URL"], let url = URL(string: address) else {
            throw XCTSkip("Set UGEN_RTSP_URL to test against a real RTSP stream.")
        }
        let client = RTSPClient(url: url, timeout: 20)
        try await client.start()
        defer { client.stop() }
        var images: [CGImage] = []
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if let image = client.takeLatest() { images.append(image) }
            try await Task.sleep(for: .milliseconds(5))
        }
        let first = try XCTUnwrap(images.first)
        print("RTSP live test: \(images.count) frames in 5 s, \(first.width)x\(first.height), failure: \(client.failure ?? "none")")
        XCTAssertGreaterThan(first.width, 0)
        XCTAssertGreaterThan(images.count, 1)
        XCTAssertNil(client.failure)
    }
}

// MARK: - Reading pixels

private struct Pixels {
    let width: Int, height: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var storage = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = storage.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        bytes = storage
    }

    /// x from the left, y from the top.
    subscript(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let offset = (y * width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
}

// MARK: - A short H.264 clip made with VideoToolbox

/// Red top-left quarter, blue top-right quarter, grey noise below with a green square moving to the right.
final class TestClip: @unchecked Sendable {
    struct Frame {
        var nals: [Data]
        var isKeyframe: Bool
    }

    static let width = 320, height = 240
    static let frameCount = 36
    static let keyframeInterval = 12
    static let squareSize = 40
    static let squareY = 160
    static func squareX(frame: Int) -> Int { 10 + frame * 7 }

    static let shared: Result<TestClip, Error> = Result { try TestClip() }

    let sps: Data
    let pps: Data
    let frames: [Frame]

    private init() throws {
        var session: VTCompressionSession?
        var status = VTCompressionSessionCreate(allocator: nil, width: Int32(Self.width), height: Int32(Self.height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw RTSPError("VTCompressionSessionCreate failed: \(status)") }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Self.keyframeInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 2_000_000 as CFNumber)

        let lock = NSLock()
        var samples: [(time: Int64, buffer: CMSampleBuffer)] = []
        var failures: [OSStatus] = []
        for index in 0..<Self.frameCount {
            let picture = try Self.makePicture(frame: index)
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            status = VTCompressionSessionEncodeFrame(session, imageBuffer: picture, presentationTimeStamp: time,
                                                     duration: CMTime(value: 1, timescale: 30), frameProperties: nil, infoFlagsOut: nil) { status, _, buffer in
                lock.withLock {
                    if status != noErr { failures.append(status) }
                    if let buffer { samples.append((CMSampleBufferGetPresentationTimeStamp(buffer).value, buffer)) }
                }
            }
            guard status == noErr else { throw RTSPError("VTCompressionSessionEncodeFrame failed: \(status)") }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let (encoded, errors) = lock.withLock { (samples.sorted { $0.time < $1.time }, failures) }
        guard errors.isEmpty, encoded.count == Self.frameCount else {
            throw RTSPError("The encoder produced \(encoded.count) of \(Self.frameCount) frames (errors: \(errors)).")
        }

        guard let format = CMSampleBufferGetFormatDescription(encoded[0].buffer) else { throw RTSPError("no format description") }
        func parameterSet(_ index: Int) throws -> Data {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                            parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { throw RTSPError("no parameter set \(index)") }
            return Data(bytes: pointer, count: size)
        }
        sps = try parameterSet(0)
        pps = try parameterSet(1)

        frames = try encoded.map { sample in
            guard let block = CMSampleBufferGetDataBuffer(sample.buffer) else { throw RTSPError("no data buffer") }
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == kCMBlockBufferNoErr else {
                throw RTSPError("could not copy the encoded frame")
            }
            // The encoder writes AVCC: 4-byte length, NAL unit, and so on.
            var nals: [Data] = []
            var offset = 0
            while offset + 4 <= bytes.count {
                let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                offset += 4
                guard length > 0, offset + length <= bytes.count else { break }
                nals.append(Data(bytes[offset..<(offset + length)]))
                offset += length
            }
            return Frame(nals: nals, isKeyframe: nals.contains { $0[0] & 0x1F == 5 })
        }
        guard frames[0].isKeyframe else { throw RTSPError("the clip does not start with a keyframe") }
    }

    private static func makePicture(frame: Int) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created)
        guard let buffer = created else { throw RTSPError("CVPixelBufferCreate failed") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw RTSPError("no pixel memory") }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let squareLeft = squareX(frame: frame)
        var seed: UInt32 = 12345
        var noiseRow = [UInt8](repeating: 0, count: width)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            if y >= height / 2, y % 2 == 0 {
                // The same noise in every frame, in 2x2 blocks: large keyframes, small frames in between.
                for x in stride(from: 0, to: width, by: 2) {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let value = UInt8(64 + (seed >> 24) / 2)
                    noiseRow[x] = value
                    noiseRow[x + 1] = value
                }
            }
            for x in 0..<width {
                var blue: UInt8, green: UInt8, red: UInt8
                if y < height / 2 {
                    (blue, green, red) = x < width / 2 ? (0, 0, 255) : (255, 0, 0)
                } else if y >= squareY, y < squareY + squareSize, x >= squareLeft, x < squareLeft + squareSize {
                    (blue, green, red) = (0, 255, 0)
                } else {
                    (blue, green, red) = (noiseRow[x], noiseRow[x], noiseRow[x])
                }
                row[x * 4] = blue
                row[x * 4 + 1] = green
                row[x * 4 + 2] = red
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }
}

// MARK: - A tiny RTSP server on 127.0.0.1

/// Just enough RTSP to serve `TestClip` over the interleaved channel, in a loop. One of everything.
final class LoopbackRTSPServer: @unchecked Sendable {
    enum Auth: Equatable {
        case none
        case basic
        case digest(qop: Bool)
    }

    struct Options {
        var auth: Auth = .none
        var parameterSetsInSDP = true
        var rejectInterleaved = false
        var hevcOnly = false
        var sendNoVideo = false
        /// Close the connection after this many frames (0: never).
        var closeAfterFrames = 0
        /// Seconds; the client should send a keep-alive at half of it.
        var sessionTimeout = 2
    }

    struct Stats {
        var openConnections = 0
        var keepAlives = 0
        var teardowns = 0
        var unauthorized = 0
        var authorized = 0
        var fragmentPackets = 0
        var aggregatePackets = 0
        var framesSent = 0
    }

    static let user = "admin", password = "s3cret pass", realm = "Loopback Camera", nonce = "5f1b9c0d7a3e4f21", opaque = "c0ffee"
    static let sessionID = "A1B2C3D4"
    static let maxPayload = 1400
    static let payloadType: UInt8 = 96

    private let clip: TestClip
    private let options: Options
    private let queue = DispatchQueue(label: "rtsp.test.server")
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var port: UInt16 = 0
    private let lock = NSLock()
    private var counters = Stats()

    var stats: Stats { lock.withLock { counters } }
    fileprivate func count(_ change: (inout Stats) -> Void) { lock.withLock { change(&counters) } }

    init(clip: TestClip, options: Options) {
        self.clip = clip
        self.options = options
    }

    func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let peer = Peer(server: self, connection: connection)
            self.peers[ObjectIdentifier(peer)] = peer
            self.count { $0.openConnections += 1 }
            peer.start()
        }
        listener.start(queue: queue)
        self.listener = listener
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue, port != 0 else {
            throw RTSPError("The test server could not listen on 127.0.0.1.")
        }
        self.port = port
        return port
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for peer in peers.values { peer.close() }
            peers.removeAll()
        }
    }

    private func sdp() -> String {
        var lines = ["v=0", "o=- 1 1 IN IP4 127.0.0.1", "s=Loopback", "t=0 0", "a=control:*",
                     "m=audio 0 RTP/AVP 0", "a=control:trackID=0"]
        if options.hevcOnly {
            lines += ["m=video 0 RTP/AVP 98", "a=rtpmap:98 H265/90000", "a=control:trackID=1"]
        } else {
            var parameters = "packetization-mode=1"
            if options.parameterSetsInSDP {
                parameters += ";sprop-parameter-sets=\(clip.sps.base64EncodedString()),\(clip.pps.base64EncodedString())"
            }
            lines += ["m=video 0 RTP/AVP \(Self.payloadType)", "a=rtpmap:\(Self.payloadType) H264/90000", "a=fmtp:\(Self.payloadType) \(parameters)",
                      "a=control:trackID=1"]
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// One client connection. Everything runs on the server's queue.
    fileprivate final class Peer {
        private unowned let server: LoopbackRTSPServer
        private let connection: NWConnection
        private var buffer = Data()
        private var timer: DispatchSourceTimer?
        private var closed = false
        private var sequence: UInt16 = 65500  // wraps around soon after the start
        private var frameIndex = 0

        init(server: LoopbackRTSPServer, connection: NWConnection) {
            self.server = server
            self.connection = connection
        }

        func start() {
            connection.start(queue: server.queue)
            receive()
        }

        func close() {
            guard !closed else { return }
            closed = true
            timer?.cancel()
            timer = nil
            connection.cancel()
            server.count { $0.openConnections -= 1 }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self, !self.closed else { return }
                if let data { self.buffer.append(data) }
                while let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let text = String(decoding: self.buffer[self.buffer.startIndex..<end.lowerBound], as: UTF8.self)
                    self.buffer = Data(self.buffer[end.upperBound...])
                    self.handle(text)
                    if self.closed { return }
                }
                if isComplete || error != nil {
                    self.close()
                    self.server.peers[ObjectIdentifier(self)] = nil
                } else {
                    self.receive()
                }
            }
        }

        private func reply(_ status: String, cseq: String, headers: [String] = [], body: String = "") {
            var text = "RTSP/1.0 \(status)\r\nCSeq: \(cseq)\r\nServer: Loopback\r\n"
            for header in headers { text += header + "\r\n" }
            if !body.isEmpty { text += "Content-Length: \(body.utf8.count)\r\n" }
            text += "\r\n" + body
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
        }

        private static func md5(_ text: String) -> String {
            Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        /// Value of `name=...` in an Authorization header, quoted or not.
        private static func parameter(_ name: String, in header: String) -> String? {
            guard let range = header.range(of: "\(name)=", options: [], range: nil, locale: nil) else { return nil }
            let rest = header[range.upperBound...]
            if rest.hasPrefix("\"") {
                let inner = rest.dropFirst()
                return inner.firstIndex(of: "\"").map { String(inner[..<$0]) }
            }
            return String(rest.prefix { $0 != "," && $0 != " " })
        }

        private func isAuthorized(method: String, uri: String, header: String?) -> Bool {
            switch server.options.auth {
            case .none:
                return true
            case .basic:
                return header == "Basic " + Data("\(LoopbackRTSPServer.user):\(LoopbackRTSPServer.password)".utf8).base64EncodedString()
            case .digest(let qop):
                guard let header, header.hasPrefix("Digest "),
                      Self.parameter("username", in: header) == LoopbackRTSPServer.user,
                      Self.parameter("realm", in: header) == LoopbackRTSPServer.realm,
                      Self.parameter("nonce", in: header) == LoopbackRTSPServer.nonce,
                      Self.parameter("uri", in: header) == uri,
                      let response = Self.parameter("response", in: header) else { return false }
                let ha1 = Self.md5("\(LoopbackRTSPServer.user):\(LoopbackRTSPServer.realm):\(LoopbackRTSPServer.password)")
                let ha2 = Self.md5("\(method):\(uri)")
                if qop {
                    guard Self.parameter("qop", in: header) == "auth", Self.parameter("opaque", in: header) == LoopbackRTSPServer.opaque,
                          let count = Self.parameter("nc", in: header), count.count == 8,
                          let cnonce = Self.parameter("cnonce", in: header), !cnonce.isEmpty else { return false }
                    return response == Self.md5("\(ha1):\(LoopbackRTSPServer.nonce):\(count):\(cnonce):auth:\(ha2)")
                }
                return response == Self.md5("\(ha1):\(LoopbackRTSPServer.nonce):\(ha2)")
            }
        }

        private func handle(_ text: String) {
            let lines = text.components(separatedBy: "\r\n")
            let requestLine = lines[0].split(separator: " ")
            guard requestLine.count == 3, requestLine[2] == "RTSP/1.0" else {
                reply("400 Bad Request", cseq: "0")
                return
            }
            let method = String(requestLine[0]), uri = String(requestLine[1])
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let cseq = headers["cseq"] ?? "0"
            let base = "rtsp://127.0.0.1:\(server.port)/stream/"

            if method != "OPTIONS" || headers["session"] != nil {
                guard isAuthorized(method: method, uri: uri, header: headers["authorization"]) else {
                    server.count { $0.unauthorized += 1 }
                    var challenge: [String] = []
                    switch server.options.auth {
                    case .none: break
                    case .basic: challenge = ["WWW-Authenticate: Basic realm=\"\(LoopbackRTSPServer.realm)\""]
                    case .digest(let qop):
                        let extra = qop ? ", qop=\"auth\", opaque=\"\(LoopbackRTSPServer.opaque)\", algorithm=MD5" : ""
                        // A camera that offers both, Basic first.
                        challenge = ["WWW-Authenticate: Basic realm=\"\(LoopbackRTSPServer.realm)\"",
                                     "WWW-Authenticate: Digest realm=\"\(LoopbackRTSPServer.realm)\", nonce=\"\(LoopbackRTSPServer.nonce)\"\(extra)"]
                        if qop { challenge.removeFirst() }
                    }
                    reply("401 Unauthorized", cseq: cseq, headers: challenge)
                    return
                }
                if server.options.auth != .none { server.count { $0.authorized += 1 } }
            }

            switch method {
            case "OPTIONS":
                reply("200 OK", cseq: cseq, headers: ["Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER"])
            case "DESCRIBE":
                guard uri == "rtsp://127.0.0.1:\(server.port)/stream", headers["accept"]?.contains("application/sdp") == true else {
                    reply("404 Not Found", cseq: cseq)
                    return
                }
                reply("200 OK", cseq: cseq, headers: ["Content-Base: \(base)", "Content-Type: application/sdp"], body: server.sdp())
            case "SETUP":
                guard uri == base + "trackID=1" else {
                    reply("404 Not Found", cseq: cseq)
                    return
                }
                guard !server.options.rejectInterleaved, headers["transport"]?.contains("RTP/AVP/TCP") == true,
                      headers["transport"]?.contains("interleaved=0-1") == true else {
                    reply("461 Unsupported Transport", cseq: cseq)
                    return
                }
                reply("200 OK", cseq: cseq, headers: ["Transport: RTP/AVP/TCP;unicast;interleaved=0-1;ssrc=11223344;mode=\"PLAY\"",
                                                      "Session: \(LoopbackRTSPServer.sessionID);timeout=\(server.options.sessionTimeout)"])
            case "PLAY":
                guard headers["session"] == LoopbackRTSPServer.sessionID, uri == base else {
                    reply("454 Session Not Found", cseq: cseq)
                    return
                }
                reply("200 OK", cseq: cseq, headers: ["Session: \(LoopbackRTSPServer.sessionID)", "RTP-Info: url=\(base)trackID=1;seq=\(sequence);rtptime=0"])
                if !server.options.sendNoVideo { startStreaming() }
            case "GET_PARAMETER":
                guard headers["session"] == LoopbackRTSPServer.sessionID else {
                    reply("454 Session Not Found", cseq: cseq)
                    return
                }
                server.count { $0.keepAlives += 1 }
                reply("200 OK", cseq: cseq, headers: ["Session: \(LoopbackRTSPServer.sessionID)"])
            case "TEARDOWN":
                guard headers["session"] == LoopbackRTSPServer.sessionID else {
                    reply("454 Session Not Found", cseq: cseq)
                    return
                }
                timer?.cancel()
                timer = nil
                server.count { $0.teardowns += 1 }
                reply("200 OK", cseq: cseq)
            default:
                reply("501 Not Implemented", cseq: cseq)
            }
        }

        private func startStreaming() {
            let timer = DispatchSource.makeTimerSource(queue: server.queue)
            timer.schedule(deadline: .now() + 0.02, repeating: 0.02)
            timer.setEventHandler { [weak self] in self?.sendFrame() }
            timer.resume()
            self.timer = timer
        }

        private func packet(marker: Bool, timestamp: UInt32, payload: [UInt8]) -> [UInt8] {
            let length = payload.count + 12
            var bytes: [UInt8] = [0x24, 0, UInt8(length >> 8), UInt8(length & 0xFF),
                                  0x80, (marker ? 0x80 : 0) | LoopbackRTSPServer.payloadType, UInt8(sequence >> 8), UInt8(sequence & 0xFF),
                                  UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xFF), UInt8((timestamp >> 8) & 0xFF), UInt8(timestamp & 0xFF),
                                  0x11, 0x22, 0x33, 0x44]
            bytes += payload
            sequence &+= 1
            return bytes
        }

        private func sendFrame() {
            guard !closed else { return }
            let limit = server.options.closeAfterFrames
            if limit > 0, frameIndex >= limit {
                close()
                server.peers[ObjectIdentifier(self)] = nil
                return
            }
            let clip = server.clip
            let frame = clip.frames[frameIndex % clip.frames.count]
            // Starts near the top of the 32-bit range so that the timestamp wraps around during the test.
            let timestamp = UInt32(truncatingIfNeeded: 4_294_900_000 + frameIndex * 3000)
            var out: [UInt8] = []
            var fragments = 0, aggregates = 0
            if frame.isKeyframe {
                // SPS and PPS together in one STAP-A packet.
                var payload: [UInt8] = [0x78]
                for set in [clip.sps, clip.pps] {
                    payload += [UInt8(set.count >> 8), UInt8(set.count & 0xFF)] + set
                }
                out += packet(marker: false, timestamp: timestamp, payload: payload)
                aggregates += 1
            }
            for (index, nal) in frame.nals.enumerated() {
                let last = index == frame.nals.count - 1
                let bytes = [UInt8](nal)
                if bytes.count <= LoopbackRTSPServer.maxPayload {
                    out += packet(marker: last, timestamp: timestamp, payload: bytes)
                    continue
                }
                // FU-A: the NAL header is split into an indicator and a fragment header.
                let indicator = (bytes[0] & 0xE0) | 28
                var offset = 1
                while offset < bytes.count {
                    let end = min(bytes.count, offset + LoopbackRTSPServer.maxPayload - 2)
                    var fragmentHeader = bytes[0] & 0x1F
                    if offset == 1 { fragmentHeader |= 0x80 }
                    if end == bytes.count { fragmentHeader |= 0x40 }
                    out += packet(marker: last && end == bytes.count, timestamp: timestamp, payload: [indicator, fragmentHeader] + bytes[offset..<end])
                    fragments += 1
                    offset = end
                }
            }
            // Something on the RTCP channel, which the client has to skip.
            if frameIndex % 10 == 0 { out += [0x24, 1, 0, 8, 0x80, 200, 0, 1, 0x11, 0x22, 0x33, 0x44] }
            frameIndex += 1
            server.count {
                $0.fragmentPackets += fragments
                $0.aggregatePackets += aggregates
                $0.framesSent += 1
            }
            connection.send(content: Data(out), completion: .contentProcessed { _ in })
        }
    }
}
