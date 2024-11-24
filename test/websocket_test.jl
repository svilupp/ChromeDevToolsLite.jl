@testset "WebSocket Connection Tests" begin
    # Test basic connection
    client = connect_browser(ENDPOINT)
    @test client isa WSClient
    @test !isnothing(client.ws)
    @test client.next_id == 1
    @test client.page_loaded == false

    # Test connection status
    @test client.is_connected == true

    # Enable necessary domains with error checking
    enable_page = send_cdp(client, "Page.enable")
    @test haskey(enable_page, "result")

    enable_runtime = send_cdp(client, "Runtime.enable")
    @test haskey(enable_runtime, "result")

    # Test page navigation
    response = send_cdp(
        client, "Page.navigate", Dict{String, Any}("url" => "https://www.example.com"))
    @test haskey(response, "result") || error("Navigation failed: $response")
    @test haskey(response["result"], "frameId") ||
          error("No frameId in response: $response")

    # Wait for page load event
    sleep(2)  # Add reasonable wait time for page load

    # Test JavaScript evaluation
    eval_response = send_cdp(client, "Runtime.evaluate",
        Dict{String, Any}(
            "expression" => "document.title",
            "returnByValue" => true
        ))

    @test haskey(eval_response, "result") ||
          error("JavaScript evaluation failed: $(eval_response)")
    @test haskey(eval_response["result"], "result") ||
          error("No result in evaluation response: $(eval_response)")
    @test haskey(eval_response["result"]["result"], "value") ||
          error("No value in evaluation result: $(eval_response["result"])")

    title = eval_response["result"]["result"]["value"]
    @test title == "Example Domain" || error("Unexpected page title: $title")

    ## Connection Timeout test
    # Test connection timeout
    @test_throws TimeoutError send_cdp(client, "Runtime.evaluate",
        Dict{String, Any}(
            "expression" => """
                new Promise((resolve) => {
                    // Sleep longer than CONNECTION_TIMEOUT
                    setTimeout(resolve, 1000);
                });
            """,
            "awaitPromise" => true
        ), timeout = 0.1)

    # Test connection closure
    close(client)
    @test isnothing(client.ws)
    @test client.is_connected == false
end
