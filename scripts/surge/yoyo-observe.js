// Query Yoyo for the owning process launch timezone; Surge chooses the policy.
// argument=Los_Angeles matches the final component of the launch timezone.
// JSON arguments also support {"timezone":"Los_Angeles","endpoint":"http://127.0.0.1:47643/v1/surge/request"}.
var finished = false;
function finish(matched) {
    if (!finished) { finished = true; $done({matched: matched === true}); }
}
if (typeof $environment !== "object" || !$environment || $environment.system !== "macOS") {
    finish(false);
} else {
try {
    setTimeout(function () { finish(false); }, 450);
    var argument = typeof $argument === "string" ? $argument.trim() : "";
    var options = argument ? (argument.charAt(0) === "{" ? JSON.parse(argument) : {timezone: argument}) : {};
    var endpoint = options.endpoint || "http://127.0.0.1:47643/v1/surge/request";
    var local = /^http:\/\/(127\.0\.0\.1|localhost|\[::1\]):(\d+)\//.exec(endpoint);
    if (!local) throw new Error("Yoyo endpoint must be loopback HTTP");
    var request = typeof $request === "object" && $request ? $request : {};
    // Script HTTP requests also enter Surge's traffic pipeline. Never report our own POST.
    if (Number(request.destPort) === Number(local[2]) &&
        ["127.0.0.1", "localhost", "::1", "[::1]"].indexOf(request.hostname) >= 0) {
        finish();
    } else {
        var payload = {observedAt: Date.now() / 1000, argument: options.timezone || null};
        ["hostname", "destPort", "sourcePort", "protocol", "processPath", "sourceIP", "listenPort", "dnsResult", "userAgent", "url"].forEach(function (field) {
            payload[field] = request[field] === undefined ? null : request[field];
        });
        $httpClient.post({url: endpoint, policy: "DIRECT", timeout: 0.3,
            headers: {"Content-Type": "application/json"}, body: JSON.stringify(payload)}, function (error, response, body) {
            if (finished) return;
            var matched = false;
            try {
                if (error) console.log("[Yoyo] report failed: " + error);
                else if (response && response.status === 200) {
                    var report = JSON.parse(body);
                    var result = report.result;
                    matched = report.matched === true;
                    console.log("[Yoyo] matched=" + matched + " " + result.status + " pid=" + result.pid + " candidate=" + result.candidate_pid);
                }
            } catch (error) { console.log("[Yoyo] " + error); }
            finally { finish(matched); }
        });
    }
} catch (error) {
    console.log("[Yoyo] " + error);
    finish();
}
}
