import Foundation
import PiDurableKit

/// Pi normalizes absent usage fields to zero. Preserve field presence at its
/// supported provider-event hook before that normalization; never infer costs.
enum RuntimeUsageReporting {
    static func usage(_ message: AssistantMessage, id: UUID) -> AgentModelUsage {
        let values = (try? PiDurableKit.JSONValue(encoding: message))?["eiscueReportedUsage"]
        func count(_ key: String) -> Int? {
            guard let value = values?[key]?.intValue, value >= 0 else { return nil }
            return value
        }
        return AgentModelUsage(id: id, inputTokens: count("inputTokens"), outputTokens: count("outputTokens"),
                               cacheReadTokens: count("cacheReadTokens"), cacheWriteTokens: count("cacheWriteTokens"))
    }

    static let runtimeExtension = Extension("eiscue-reported-usage", javaScript: #"""
    const { defineExtension, hook, GenerationTask } = require("@earendil-works/pi-durable");
    const installed = Symbol.for("org.eiscue.reported-usage.v1");

    function install(models) {
        if (models[installed]) return;
        const original = models.streamSimple.bind(models);
        models.streamSimple = (model, context, options = {}) => {
            if (!["openai-completions", "openai-responses", "anthropic-messages"].includes(model.api)) {
                return original(model, context, options);
            }
            const usage = {};
            function copy(source, field, target) {
                if (!source || !Object.prototype.hasOwnProperty.call(source, field)) return;
                const value = source[field];
                if (Number.isSafeInteger(value) && value >= 0) usage[target] = value;
                else delete usage[target];
            }
            const stream = original(model, context, {
                ...options,
                onProviderStreamEvent: async (event, currentModel) => {
                    if (model.api === "openai-completions") {
                        copy(event?.usage, "prompt_tokens", "inputTokens");
                        copy(event?.usage, "completion_tokens", "outputTokens");
                        copy(event?.usage?.prompt_tokens_details, "cached_tokens", "cacheReadTokens");
                        copy(event?.usage?.prompt_tokens_details, "cache_write_tokens", "cacheWriteTokens");
                    } else if (model.api === "openai-responses"
                        && ["response.completed", "response.incomplete", "response.failed"].includes(event?.type)) {
                        copy(event.response?.usage, "input_tokens", "inputTokens");
                        copy(event.response?.usage, "output_tokens", "outputTokens");
                        copy(event.response?.usage?.input_tokens_details, "cached_tokens", "cacheReadTokens");
                    } else if (model.api === "anthropic-messages") {
                        const reported = event?.type === "message_start" ? event.message?.usage
                            : event?.type === "message_delta" ? event.usage : undefined;
                        copy(reported, "input_tokens", "inputTokens");
                        copy(reported, "output_tokens", "outputTokens");
                        copy(reported, "cache_read_input_tokens", "cacheReadTokens");
                        copy(reported, "cache_creation_input_tokens", "cacheWriteTokens");
                    }
                    await options.onProviderStreamEvent?.(event, currentModel);
                }
            });
            const result = stream.result.bind(stream);
            stream.result = async () => {
                const message = await result();
                // One snapshot per response, not a sum of cumulative chunks.
                message.eiscueReportedUsage = { ...usage };
                return message;
            };
            return stream;
        };
        Object.defineProperty(models, installed, { value: true });
    }

    module.exports = defineExtension({
        name: "eiscue-reported-usage",
        hooks: [hook(GenerationTask, { beforeRequest(request, api) { install(api.models); } })]
    });
    """#)
}
