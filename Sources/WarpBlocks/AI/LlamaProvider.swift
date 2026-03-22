import Foundation
import LlamaSwift

struct LlamaProvider: AIProvider {
    func stream(prompt: String, history: [AIMessage]) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try LlamaRunner.shared.stream(prompt: prompt, history: history, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private enum LlamaRunnerError: Error {
    case noModelPath
    case modelLoadFailed
    case contextFailed
    case tokenizeFailed
    case decodeFailed
}

private final class LlamaRunner {
    static let shared = LlamaRunner()
    private let lock = NSLock()
    private var backendInitialized = false
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var loadedPath: String?

    /// Serialized: llama.cpp context is not thread-safe, so the lock
    /// spans load + generate. Concurrent callers block until completion.
    func stream(
        prompt: String,
        history: [AIMessage],
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) throws {
        let path = resolveModelPath()
        guard let path else {
            throw LlamaRunnerError.noModelPath
        }

        lock.lock()
        defer { lock.unlock() }
        if loadedPath != path || model == nil {
            freeModel()
            try load(path: path)
        } else {
            try resetContextKeepingModel()
        }
        guard let model, let context else {
            throw LlamaRunnerError.modelLoadFailed
        }

        let fullPrompt = formatPrompt(history: history, prompt: prompt)
        try runGenerate(model: model, context: context, fullPrompt: fullPrompt, continuation: continuation)
    }

    private func resolveModelPath() -> String? {
        if let env = ProcessInfo.processInfo.environment["GHOSTWARP_MODEL"], !env.isEmpty {
            return env
        }
        if let d = UserDefaults.standard.string(forKey: "warpblocks.llamaModelPath"), !d.isEmpty {
            return d
        }
        return nil
    }

    private func load(path: String) throws {
        if !backendInitialized {
            llama_backend_init()
            backendInitialized = true
        }
        var mparams = llama_model_default_params()
        guard let m = llama_model_load_from_file(path, mparams) else {
            throw LlamaRunnerError.modelLoadFailed
        }
        model = m
        loadedPath = path
        var cparams = llama_context_default_params()
        cparams.n_ctx = 4096
        cparams.n_batch = 512
        guard let ctx = llama_init_from_model(m, cparams) else {
            throw LlamaRunnerError.contextFailed
        }
        context = ctx
    }

    private func resetContextKeepingModel() throws {
        guard let m = model else {
            throw LlamaRunnerError.modelLoadFailed
        }
        if let ctx = context {
            llama_free(ctx)
            context = nil
        }
        var cparams = llama_context_default_params()
        cparams.n_ctx = 4096
        cparams.n_batch = 512
        guard let ctx = llama_init_from_model(m, cparams) else {
            throw LlamaRunnerError.contextFailed
        }
        context = ctx
    }

    private func freeModel() {
        if let ctx = context {
            llama_free(ctx)
            context = nil
        }
        if let m = model {
            llama_model_free(m)
            model = nil
        }
        loadedPath = nil
    }

    private func formatPrompt(history: [AIMessage], prompt: String) -> String {
        var parts: [String] = []
        parts.append("<|im_start|>system\nYou are a helpful assistant.<|im_end|>")
        for m in history {
            parts.append("<|im_start|>\(m.role)\n\(m.content)<|im_end|>")
        }
        parts.append("<|im_start|>user\n\(prompt)<|im_end|>")
        parts.append("<|im_start|>assistant\n")
        return parts.joined(separator: "\n")
    }

    private func runGenerate(
        model: OpaquePointer,
        context: OpaquePointer,
        fullPrompt: String,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) throws {
        let vocab = llama_model_get_vocab(model)
        let byteCount = Int32(fullPrompt.utf8.count)
        let maxTokenCount = Int(byteCount) + 32
        var tokens = [llama_token](repeating: 0, count: maxTokenCount)
        let n = llama_tokenize(
            vocab,
            fullPrompt,
            byteCount,
            &tokens,
            Int32(maxTokenCount),
            true,
            true
        )
        guard n > 0 else { throw LlamaRunnerError.tokenizeFailed }
        let promptTokens = Array(tokens.prefix(Int(n)))

        var cparams = llama_context_default_params()
        var batch = llama_batch_init(Int32(cparams.n_batch), 0, 1)
        defer { llama_batch_free(batch) }

        batch.n_tokens = Int32(promptTokens.count)
        for i in 0 ..< promptTokens.count {
            let idx = Int(i)
            batch.token[idx] = promptTokens[idx]
            batch.pos[idx] = Int32(i)
            batch.n_seq_id[idx] = 1
            if let seq_ids = batch.seq_id, let seq_id = seq_ids[idx] {
                seq_id[0] = 0
            }
            batch.logits[idx] = 0
        }
        if batch.n_tokens > 0 {
            batch.logits[Int(batch.n_tokens) - 1] = 1
        }
        guard llama_decode(context, batch) == 0 else {
            throw LlamaRunnerError.decodeFailed
        }

        var nCur = batch.n_tokens
        let eos = llama_vocab_eos(vocab)
        var promptCount = Int(n)
        var completionCount = 0
        let maxGen = 512

        for _ in 0 ..< maxGen {
            if Task.isCancelled { break }
            guard let logits = llama_get_logits_ith(context, Int32(batch.n_tokens - 1)) else {
                break
            }
            let vocabSize = llama_vocab_n_tokens(vocab)
            var maxLogit = logits[0]
            var nextToken: llama_token = 0
            for i in 1 ..< Int(vocabSize) {
                if logits[i] > maxLogit {
                    maxLogit = logits[i]
                    nextToken = llama_token(i)
                }
            }
            if nextToken == eos {
                break
            }
            var buffer = [CChar](repeating: 0, count: 256)
            let length = llama_token_to_piece(
                vocab,
                nextToken,
                &buffer,
                Int32(buffer.count),
                0,
                false
            )
            if length > 0 {
                let piece = String(cString: buffer)
                if !piece.isEmpty {
                    continuation.yield(.text(piece))
                }
            }
            completionCount += 1

            batch.n_tokens = 1
            batch.token[0] = nextToken
            batch.pos[0] = nCur
            batch.n_seq_id[0] = 1
            if let seq_ids = batch.seq_id, let seq_id = seq_ids[0] {
                seq_id[0] = 0
            }
            batch.logits[0] = 1
            nCur += 1
            guard llama_decode(context, batch) == 0 else {
                throw LlamaRunnerError.decodeFailed
            }
        }
        continuation.yield(.done(promptTokens: promptCount, completionTokens: completionCount))
    }
}
