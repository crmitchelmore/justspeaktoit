#include "WindowsAutomationPipeInternal.hpp"

// The server side: one listener owns the pipe name, its pending instance and
// the connections it accepted. stop() waits for in-progress I/O (BusyScope)
// before it closes any handle.

using namespace jsti::automation;

int jsti_automation_pipe_listen(const char *pipeName, uint32_t maxInstances, JSTIAutomationPipeListener **result,
                                char *error, size_t capacity) {
    if (!result) return fail(JSTI_AUTOMATION_PIPE_FAILED, "No listener output supplied.", error, capacity);
    *result = nullptr;
    std::wstring name;
    if (!localPipeName(pipeName, name) || maxInstances < 1 || maxInstances > 64) {
        return fail(JSTI_AUTOMATION_PIPE_FAILED, "The automation pipe name or instance count is invalid.", error,
                    capacity);
    }
    try {
        auto listener = std::make_shared<JSTIAutomationPipeListener>();
        listener->name = name;
        listener->maxInstances = maxInstances;
        DWORD code = 0;
        if (!listener->stopEvent.value || !listener->slotEvent.value || !pipeSecurity(listener->security, code)) {
            return systemFail(JSTI_AUTOMATION_PIPE_FAILED, "Prepare the automation pipe", code ? code : GetLastError(),
                              error, capacity);
        }
        listener->pending = listener->createInstance(true, code);
        if (listener->pending == INVALID_HANDLE_VALUE) {
            if (code == ERROR_ACCESS_DENIED || code == ERROR_PIPE_BUSY) {
                return fail(JSTI_AUTOMATION_PIPE_IN_USE, "Another process already owns the automation pipe.", error,
                            capacity);
            }
            return systemFail(JSTI_AUTOMATION_PIPE_FAILED, "Create the automation pipe", code, error, capacity);
        }
        listener->self = listener;
        *result = listener.get();
        return JSTI_AUTOMATION_PIPE_OK;
    } catch (const std::exception &) {
        return fail(JSTI_AUTOMATION_PIPE_FAILED, "Could not allocate the automation listener.", error, capacity);
    }
}

int jsti_automation_pipe_accept(JSTIAutomationPipeListener *raw, JSTIAutomationPipeConnection **result, char *error,
                                size_t capacity) {
    if (!raw || !result) return fail(JSTI_AUTOMATION_PIPE_FAILED, "Invalid automation accept.", error, capacity);
    *result = nullptr;
    const std::shared_ptr<JSTIAutomationPipeListener> listener = raw->self;
    if (!listener) return fail(JSTI_AUTOMATION_PIPE_CANCELLED, "The automation listener stopped.", error, capacity);
    while (true) {
        HANDLE pipe = INVALID_HANDLE_VALUE;
        {
            std::lock_guard<std::mutex> lock(listener->mutex);
            if (listener->stopped) {
                return fail(JSTI_AUTOMATION_PIPE_CANCELLED, "The automation listener stopped.", error, capacity);
            }
            if (listener->pending == INVALID_HANDLE_VALUE) {
                DWORD code = 0;
                listener->pending = listener->createInstance(false, code);
                if (listener->pending == INVALID_HANDLE_VALUE && code != ERROR_PIPE_BUSY) {
                    return systemFail(JSTI_AUTOMATION_PIPE_FAILED, "Create an automation pipe instance", code, error,
                                      capacity);
                }
            }
            pipe = listener->pending;
        }
        if (pipe == INVALID_HANDLE_VALUE) {
            // Every instance is serving a client: wait for one to close.
            HANDLE waits[] = {listener->slotEvent.value, listener->stopEvent.value};
            WaitForMultipleObjects(2, waits, FALSE, INFINITE);
            continue;
        }
        // Counted as in-progress I/O, so stop never closes the instance under this wait.
        BusyScope busy(listener);
        if (!busy.admitted) {
            return fail(JSTI_AUTOMATION_PIPE_CANCELLED, "The automation listener stopped.", error, capacity);
        }
        Operation operation;
        if (!operation.event.value) {
            return systemFail(JSTI_AUTOMATION_PIPE_FAILED, "Create automation accept event", GetLastError(), error,
                              capacity);
        }
        bool connected = ConnectNamedPipe(pipe, &operation.overlapped) != FALSE;
        DWORD code = connected ? ERROR_SUCCESS : GetLastError();
        if (!connected && code == ERROR_PIPE_CONNECTED) connected = true;
        if (!connected && code == ERROR_IO_PENDING) {
            HANDLE waits[] = {operation.event.value, listener->stopEvent.value};
            const DWORD outcome = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
            if (outcome != WAIT_OBJECT_0) CancelIoEx(pipe, &operation.overlapped);
            DWORD ignored = 0;
            connected = GetOverlappedResult(pipe, &operation.overlapped, &ignored, TRUE) != FALSE;
            code = connected ? ERROR_SUCCESS : GetLastError();
            if (outcome != WAIT_OBJECT_0) connected = false;
        }
        if (listenerStopped(listener)) {
            return fail(JSTI_AUTOMATION_PIPE_CANCELLED, "The automation listener stopped.", error, capacity);
        }
        if (!connected) {
            // A client that connected and vanished: recycle the instance.
            DisconnectNamedPipe(pipe);
            if (code == ERROR_NO_DATA || code == ERROR_BROKEN_PIPE) continue;
            return systemFail(JSTI_AUTOMATION_PIPE_FAILED, "Accept an automation client", code, error, capacity);
        }
        try {
            auto *connection = new JSTIAutomationPipeConnection();
            connection->pipe = pipe;
            connection->server = true;
            connection->listener = listener;
            std::lock_guard<std::mutex> lock(listener->mutex);
            if (listener->stopped) {
                delete connection;
                return fail(JSTI_AUTOMATION_PIPE_CANCELLED, "The automation listener stopped.", error, capacity);
            }
            listener->connections.insert(connection);
            // A replacement instance keeps the name reachable while this client is served.
            DWORD ignored = 0;
            listener->pending = listener->createInstance(false, ignored);
            *result = connection;
            return JSTI_AUTOMATION_PIPE_OK;
        } catch (const std::exception &) {
            DisconnectNamedPipe(pipe);
            return fail(JSTI_AUTOMATION_PIPE_FAILED, "Could not allocate an automation connection.", error, capacity);
        }
    }
}

int jsti_automation_pipe_wait_for_stop(JSTIAutomationPipeListener *listener, uint32_t timeout) {
    if (!listener) return 1;
    return WaitForSingleObject(listener->stopEvent.value, timeout) == WAIT_OBJECT_0 ? 1 : 0;
}

int jsti_automation_pipe_stop(JSTIAutomationPipeListener *listener, uint32_t timeout) {
    if (!listener) return JSTI_AUTOMATION_PIPE_OK;
    std::unique_lock<std::mutex> lock(listener->mutex);
    listener->stopped = true;
    SetEvent(listener->stopEvent.value);
    if (listener->pending != INVALID_HANDLE_VALUE) CancelIoEx(listener->pending, nullptr);
    for (auto *connection : listener->connections) {
        if (connection->pipe != INVALID_HANDLE_VALUE) CancelIoEx(connection->pipe, nullptr);
    }
    if (!listener->idle.wait_for(lock, std::chrono::milliseconds(timeout), [&] { return listener->busy == 0; })) {
        return JSTI_AUTOMATION_PIPE_TIMED_OUT;
    }
    // Closing the pending instance can race the accept thread's wait; that
    // thread observes the stop event and never touches the handle again.
    if (listener->pending != INVALID_HANDLE_VALUE) {
        CloseHandle(listener->pending);
        listener->pending = INVALID_HANDLE_VALUE;
    }
    for (auto *connection : listener->connections) {
        if (connection->pipe != INVALID_HANDLE_VALUE) {
            DisconnectNamedPipe(connection->pipe);
            CloseHandle(connection->pipe);
            connection->pipe = INVALID_HANDLE_VALUE;
        }
    }
    return JSTI_AUTOMATION_PIPE_OK;
}

void jsti_automation_pipe_listener_release(JSTIAutomationPipeListener *listener) {
    if (!listener) return;
    jsti_automation_pipe_stop(listener, 5000);
    std::shared_ptr<JSTIAutomationPipeListener> keep;
    {
        std::lock_guard<std::mutex> lock(listener->mutex);
        keep.swap(listener->self);
    }
    // Remaining connections hold their own references.
}
