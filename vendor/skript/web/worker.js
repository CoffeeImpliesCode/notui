/*
 * web/worker.js
 *
 * Runs skriptPad evaluations inside a Web Worker so long synchronous wasm
 * evals never block the page. The main thread only exchanges JSON messages
 * (see the protocol below); all wasm memory work happens here.
 *
 * Protocol (JSON via postMessage):
 *   worker -> main: { type: "ready" }                       wasm ready, scratch allocated
 *   worker -> main: { type: "out", id, text }               streamed output chunk for eval `id`
 *   worker -> main: { type: "done", id, rc }                eval `id` finished (rc = skriptPad return code)
 *   worker -> main: { type: "error", id?, message, fatal? } eval or worker failure
 *   worker -> main: { type: "title", text }                 jsSetTitle forwarding
 *   main -> worker: { type: "eval", id, src }               evaluate source (processed in order)
 */
"use strict";

var wasmInstance = null;
var scratchPtr = 0;
var SCRATCH_LEN = 1 << 16;
var currentId = 0; // id of the eval currently running (used by jsWrite)
var workerFatal = false;
var assetRevision = "";

function errorText(value) {
    if (value && value.message) return String(value.message);
    return String(value || "unknown worker error");
}

function readAssetRevision() {
    return new URL(self.location.href).searchParams.get("v") || "";
}

function assetQuery() {
    return assetRevision ? "?v=" + encodeURIComponent(assetRevision) : "";
}

function postFatal(value) {
    if (workerFatal) return;
    workerFatal = true;
    try {
        postMessage({ type: "error", fatal: true, message: errorText(value) });
    } catch (e) {}
}

function postEvalError(id, value) {
    if (workerFatal) return;
    try {
        postMessage({ type: "error", fatal: false, id: id, message: errorText(value) });
    } catch (e) {
        postFatal(e);
    }
}

self.onerror = function (message, source, line, column, error) {
    postFatal(error || message);
    return true;
};
self.onunhandledrejection = function (ev) {
    postFatal(ev && ev.reason ? ev.reason : "unhandled worker rejection");
};

assetRevision = readAssetRevision();
try {
    importScripts("skript.js" + assetQuery());
} catch (e) {
    postFatal(e);
}

// Emscripten's JS library forwards output to Module.skriptWrite. The
// ZigZag WASM object also imports the same callback directly as zigzag.jsWrite.
// Keep decoding and message routing here instead of using an aborting stub.
function skriptWrite(ptr, len) {
    if (workerFatal) return;
    try {
        var bytes = new Uint8Array(wasmInstance.exports.memory.buffer, ptr, len);
        var text = new TextDecoder().decode(bytes);
        postMessage({ type: "out", id: currentId, text: text });
    } catch (e) {
        postFatal(e);
    }
}

function addZigzagImports(imports) {
    // Keep Emscripten's env and runtime imports intact. The ZigZag WASM
    // object has one direct host import: zigzag.jsWrite.
    var zigzag = imports.zigzag || {};
    zigzag.jsWrite = skriptWrite;
    imports.zigzag = zigzag;
}

function instantiateWasm(imports, successCallback) {
    if (workerFatal) return;
    try {
        addZigzagImports(imports);
        fetch("skript.wasm" + assetQuery()).then(function (resp) {
            if (!resp.ok) throw new Error("Wasm request failed (" + resp.status + ")");
            return resp.arrayBuffer();
        }).then(function (bytes) {
            return WebAssembly.instantiate(bytes, imports);
        }).then(function (result) {
            if (workerFatal) return;
            wasmInstance = result.instance;
            successCallback(result.instance, result.module);
        }).catch(postFatal);
    } catch (e) {
        postFatal(e);
    }
}

if (!workerFatal) {
    if (typeof createSkript !== "function") {
        postFatal("skript.js did not provide createSkript");
    } else {
        try {
            createSkript({
                instantiateWasm: instantiateWasm,
                skriptWrite: skriptWrite,
            }).then(function () {
                if (workerFatal || !wasmInstance) return;
                try {
                    scratchPtr = wasmInstance.exports.malloc(SCRATCH_LEN);
                    if (!scratchPtr) throw new Error("could not allocate Wasm scratch space");
                    postMessage({ type: "ready" });
                } catch (e) {
                    postFatal(e);
                }
            }).catch(postFatal);
        } catch (e) {
            postFatal(e);
        }
    }
}

onmessage = function (ev) {
    if (workerFatal) return;
    try {
        var msg = ev.data;
        if (!msg || msg.type !== "eval") {
            postFatal("invalid worker request");
            return;
        }
        if (typeof msg.id !== "number" || !isFinite(msg.id) || Math.floor(msg.id) !== msg.id) {
            postFatal("invalid evaluation id");
            return;
        }
        if (typeof msg.src !== "string") {
            postEvalError(msg.id, "evaluation source must be text");
            return;
        }
        if (!wasmInstance || !scratchPtr) {
            postEvalError(msg.id, "worker is not ready");
            return;
        }
        var bytes = new TextEncoder().encode(msg.src);
        if (bytes.length > SCRATCH_LEN) {
            postEvalError(msg.id, "evaluation source exceeds the 64 KiB limit");
            return;
        }
        currentId = msg.id;
        // Fresh view against the CURRENT memory buffer: wasm memory may have
        // grown (ALLOW_MEMORY_GROWTH), which detaches earlier views.
        var view = new Uint8Array(wasmInstance.exports.memory.buffer, scratchPtr, SCRATCH_LEN);
        view.set(bytes);
        // A synchronous Wasm exception may leave the runtime unsafe. Treat it
        // as terminal instead of allowing later callbacks to remain pending.
        var rc = wasmInstance.exports.skriptPad(scratchPtr, bytes.length);
        postMessage({ type: "done", id: msg.id, rc: rc });
    } catch (e) {
        postFatal(e);
    }
};
