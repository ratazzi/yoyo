import {readFileSync} from "node:fs";
import {runInNewContext} from "node:vm";
import assert from "node:assert/strict";

const script = readFileSync("scripts/surge/yoyo-observe.js", "utf8");
for (const environment of [undefined, null, {}, {system: "iOS"}, {system: "tvOS"}, {system: "unknown"}]) {
    const completed = [];
    const context = {
        $done: value => completed.push(value.matched),
        setTimeout() { assert.fail("Unsupported platform must not schedule a timer"); },
        $httpClient: {post() { assert.fail("Unsupported platform must not call Yoyo"); }}
    };
    if (environment !== undefined) context.$environment = environment;
    runInNewContext(script, context);
    assert.deepEqual(completed, [false], "Only macOS may continue");
}
for (const mode of ["success", "match", "zone-match", "zone-mismatch", "zone-json", "server-match", "http-error", "error", "throw", "never", "bad-response", "recursive", "bad-argument"]) {
    const completed = [], timers = [], sent = [];
    const request = {hostname: "example.test", sourcePort: 51000, destPort: 443,
        protocol: "HTTPS", processPath: "/test/app", sourceIP: "127.0.0.1", listenPort: 6152};
    if (mode === "recursive") Object.assign(request, {hostname: "127.0.0.1", destPort: 47643});
    runInNewContext(script, {
        $environment: {system: "macOS"},
        $request: request,
        $argument: mode === "bad-argument" ? "{" : mode === "zone-match" ? "Los_Angeles" : ["zone-mismatch", "server-match"].includes(mode) ? "Paris" : mode === "zone-json" ? JSON.stringify({timezone: "Los_Angeles"}) : "",
        $done: value => completed.push(value.matched),
        console: {log() {}},
        setTimeout: fn => timers.push(fn),
        $httpClient: {post(options, callback) {
            sent.push(options);
            if (mode === "throw") throw new Error("offline");
            if (mode === "never") return;
            callback(mode === "error" ? "timeout" : null, {status: mode === "http-error" ? 500 : 200},
                mode === "bad-response" ? "not json" : JSON.stringify({matched: ["zone-match", "zone-json", "server-match"].includes(mode), timezone: "America/Los_Angeles", result: {status: "socket_unique", pid: 123}}));
        }}
    });
    for (const timer of timers) timer();
    assert.deepEqual(completed, [["zone-match", "zone-json", "server-match"].includes(mode)], mode + " must finish once and only accept the launch timezone");
    if (mode === "recursive" || mode === "bad-argument") assert.equal(sent.length, 0);
    else {
        assert.equal(sent.length, 1);
        assert.equal(sent[0].policy, "DIRECT");
        const payload = JSON.parse(sent[0].body);
        assert.equal(payload.sourcePort, request.sourcePort);
        assert.equal(payload.argument, ["zone-match", "zone-json"].includes(mode) ? "Los_Angeles" : ["zone-mismatch", "server-match"].includes(mode) ? "Paris" : null);
    }
}
console.log("Surge rule: receiver match decision, unmatched failure/timeout, single completion and recursion guard: PASS");
