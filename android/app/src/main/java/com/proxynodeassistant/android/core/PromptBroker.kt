package com.proxynodeassistant.android.core

import com.proxynodeassistant.android.model.PromptKind
import com.proxynodeassistant.android.model.WorkflowPrompt
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.atomic.AtomicLong

class PromptBroker {
    private val sequence = AtomicLong(1)
    private val _prompt = MutableStateFlow<WorkflowPrompt?>(null)
    val prompt: StateFlow<WorkflowPrompt?> = _prompt.asStateFlow()
    private var response: CompletableDeferred<String>? = null

    suspend fun ask(
        title: String,
        message: String,
        kind: PromptKind,
        placeholder: String = "",
        defaultValue: String = "",
        options: List<String> = emptyList(),
        danger: Boolean = false,
    ): String {
        check(response == null) { "another prompt is already active" }
        val pending = CompletableDeferred<String>()
        response = pending
        _prompt.value = WorkflowPrompt(sequence.getAndIncrement(), title, message, kind, placeholder, defaultValue, options, danger)
        return try {
            pending.await()
        } finally {
            response = null
            _prompt.value = null
        }
    }

    fun submit(value: String): Boolean {
        val pending = response ?: return false
        if (pending.isCompleted) return false
        pending.complete(value)
        return true
    }

    fun cancel() {
        response?.cancel()
        response = null
        _prompt.value = null
    }
}
