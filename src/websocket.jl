"""
    start_message_handler(client::WSClient)

Start an asynchronous task to handle incoming WebSocket messages.
"""
function start_message_handler(client::WSClient)
    @async begin
        try
            while client.is_connected && !isnothing(client.ws)
                try
                    msg = WebSockets.receive(client.ws)
                    if !isnothing(msg)
                        data = JSON3.read(msg, Dict)

                        # Handle Inspector.detached events
                        if get(data, "method", "") == "Inspector.detached"
                            reason = get(get(data, "params", Dict()), "reason", "unknown")
                            @warn "Chrome DevTools detached" reason=reason

                            if reason ∈ ["target_closed", "Render process gone."]
                                client.is_connected = false
                                break
                            end
                        end

                        put!(client.message_channel, data)
                    end
                catch e
                    if isa(e, WebSocketError) && e.status == 1000
                        @debug "WebSocket closed normally"
                        break
                    elseif isa(e, ArgumentError) && occursin("receive() requires", e.msg)
                        @debug "WebSocket connection closed"
                        break
                    else
                        @error "Error receiving message" exception=e
                        client.is_connected = false
                        break
                    end
                end
            end
        finally
            client.is_connected = false
        end
    end
end

"""
    try_connect(client::WSClient; max_retries::Int = MAX_RETRIES,
        retry_delay::Real = RETRY_DELAY, verbose::Bool = false)

Attempt to establish a WebSocket connection with retry logic and timeout.
"""
function try_connect(client::WSClient; max_retries::Int = MAX_RETRIES,
        retry_delay::Real = RETRY_DELAY, verbose::Bool = false)
    with_retry(max_retries = max_retries, retry_delay = retry_delay, verbose = verbose) do
        verbose && @debug "Attempting WebSocket connection" url=client.ws_url

        # Channel for connection status
        connection_status = Channel{Union{WebSocket, Exception}}(1)

        # Connection task
        @async begin
            try
                WebSockets.open(client.ws_url; suppress_close_error = true) do ws
                    client.ws = ws
                    client.is_connected = true
                    put!(connection_status, ws)
                    # Keep connection alive
                    while client.is_connected && !WebSockets.isclosed(ws)
                        sleep(0.1)
                    end
                end
            catch e
                put!(connection_status, e)
            end
        end

        # Timeout task
        @async begin
            sleep(CONNECTION_TIMEOUT)
            if !isready(connection_status)
                put!(connection_status,
                    TimeoutError("Connection timeout after $(CONNECTION_TIMEOUT) seconds"))
            end
        end

        # Wait for connection result
        result = take!(connection_status)

        isa(result, Exception) && throw(result)

        verbose && @debug "WebSocket connection established" url=client.ws_url
        return client
    end
end

"""
    connect!(client::WSClient; max_retries::Int = MAX_RETRIES,
        retry_delay::Real = RETRY_DELAY, verbose::Bool = false)

Connect to Chrome DevTools Protocol WebSocket endpoint.
Returns the connected client.

# Arguments
- `max_retries::Int`: The maximum number of retries to establish the connection.
- `retry_delay::Real`: The delay between retries in seconds.
- `verbose::Bool`: Whether to print verbose debug information.
"""
function connect!(client::WSClient; max_retries::Int = MAX_RETRIES,
        retry_delay::Real = RETRY_DELAY, verbose::Bool = false)
    if client.is_connected
        verbose && @debug "Client already connected"
        return client
    end

    try_connect(
        client; max_retries = max_retries, retry_delay = retry_delay, verbose = verbose)
    start_message_handler(client)
    return client
end

"""
    send_cdp_message(client::WSClient, method::String, params::Dict=Dict(); increment_id::Bool=true) -> Dict

Send a Chrome DevTools Protocol message and wait for the response.

# Arguments
- `client::WSClient`: The WebSocket client to use
- `method::String`: The CDP method to call (e.g., "Page.navigate")
- `params::Dict`: Parameters for the CDP method (default: empty Dict)
- `increment_id::Bool`: Whether to increment the message ID counter (default: true)

# Returns
- `Dict`: The CDP response message

# Throws
- `TimeoutError`: If response times out
- `ConnectionError`: If connection is lost during message exchange
"""
function send_cdp_message(
        client::WSClient, method::String, params::Dict = Dict(); increment_id::Bool = true)
    if !client.is_connected || isnothing(client.ws)
        @warn "WebSocket not connected, attempting reconnection"
        try_connect(client)
    end

    # Convert params to Dict{String,Any}
    typed_params = Dict{String, Any}(String(k) => v for (k, v) in params)

    id = client.next_id
    if increment_id
        client.next_id += 1
    end

    message = Dict{String, Any}(
        "id" => id,
        "method" => method,
        "params" => typed_params
    )

    response_channel = Channel{Dict{String, Any}}(1)

    @async begin
        try
            WebSockets.send(client.ws, JSON3.write(message))

            # Add timeout for response
            timeout_task = @task begin
                sleep(CONNECTION_TIMEOUT)
                put!(response_channel,
                    Dict("error" => Dict("message" => "Response timeout")))
            end

            while client.is_connected
                msg = take!(client.message_channel)
                if haskey(msg, "id") && msg["id"] == id
                    schedule(timeout_task, InterruptException(); error = true)
                    put!(response_channel, msg)
                    break
                end
            end
        catch e
            @error "Error sending CDP message" exception=e method=method
            put!(response_channel,
                Dict("error" => Dict("message" => "Failed to send message: $e")))
        end
    end

    response = take!(response_channel)

    if haskey(response, "error")
        error("CDP Error: $(response["error"])")
    end

    return response
end

"""
    Base.close(client::WSClient)

Close the WebSocket connection and clean up resources.

# Arguments
- `client::WSClient`: The WebSocket client to close
"""
function close(client::WSClient)
    if client.is_connected && !isnothing(client.ws)
        client.is_connected = false
        try
            close(client.ws)
        catch e
            @debug "Error during WebSocket closure" exception=e
        end
        client.ws = nothing
    end
end

"""
    handle_event(client::WSClient, event::Dict)

Process CDP events.
"""
function handle_event(client::WSClient, event::Dict)
    try
        method = get(event, "method", nothing)
        if !isnothing(method)
            if method == "Page.loadEventFired"
                put!(client.message_channel, event)
            end
            # Add more event handlers as needed
        end
    catch e
        if isa(e, WebSocketError) && e.status == 1000
            # Normal close, ignore
            @debug "WebSocket closed normally"
            return
        else
            # Real error, rethrow
            rethrow(e)
        end
    end
end

"""
    is_connected(ws::WebSocket)

Check if the WebSocket connection is still active.
"""
function is_connected(ws::WebSocket)
    try
        return !WebSockets.isclosed(ws)
    catch
        return false
    end
end
