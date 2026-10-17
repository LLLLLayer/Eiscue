import Foundation
import PiDurableKit

/// The pinned runtime's JS hook replaces only one request. Keeping this transform
/// in JS avoids Swift Message decoding dropping opaque provider thought signatures.
/// Durable tool results remain intact for recovery and historical image previews.
enum DeviceImageContext {
    static func runtimeExtension(tools: [AgentTool]) throws -> Extension {
        let limits = Dictionary(uniqueKeysWithValues: tools.compactMap { tool -> (String, Int)? in
            if case .latest(let count) = tool.contextImagePolicy { return (tool.name, count) }
            return nil
        })
        let json = String(decoding: try JSONEncoder().encode(limits), as: UTF8.self)
        return Extension("eiscue-tool-image-context", javaScript: "const configuredLimits = \(json);\n" + #"""
    const { defineExtension, hook, GenerationTask } = require("@earendil-works/pi-durable");
    module.exports = defineExtension({
        name: "eiscue-tool-image-context",
        hooks: [hook(GenerationTask, {
            beforeRequest(request) {
                const remaining = new Map();
                const messages = request.messages.slice();
                for (let i = messages.length - 1; i >= 0; i--) {
                    const message = messages[i];
                    if (message.role !== "toolResult" || !Array.isArray(message.content)) continue;
                    const limit = message.details?.eiscue?.contextImageLimit ?? configuredLimits[message.toolName];
                    if (!Number.isInteger(limit) || limit < 0) continue;
                    let available = remaining.has(limit) ? remaining.get(limit) : limit;
                    let changed = false;
                    const content = message.content.slice();
                    for (let j = content.length - 1; j >= 0; j--) {
                        if (content[j].type !== "image") continue;
                        if (available > 0) { available--; continue; }
                        content[j] = { type: "text", text: "[Older tool image omitted from model context; retained in history. Observe again if needed.]" };
                        changed = true;
                    }
                    remaining.set(limit, available);
                    if (changed) messages[i] = { ...message, content };
                }
                return { messages };
            }
        })]
    });
    """#)
    }
}
