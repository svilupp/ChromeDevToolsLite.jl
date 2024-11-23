using ChromeDevToolsLite
using Test
using HTTP
using Logging

# Configure test logging
ENV["JULIA_DEBUG"] = "ChromeDevToolsLite"
logger = ConsoleLogger(stderr, Logging.Debug)
global_logger(logger)

include("test_utils.jl")

# Ensure Chrome is running before tests
@testset "ChromeDevToolsLite.jl" begin
    @info "Setting up Chrome for tests..."
    try
        # Try to set up Chrome
        setup_success = false
        setup_error = nothing

        try
            setup_success = setup_chrome()
        catch e
            setup_error = e
            @error "Chrome setup failed" exception=e
        end

        if !setup_success
            if setup_error !== nothing
                @error "Chrome setup failed" exception=setup_error
            end
            error("Failed to set up Chrome for testing")
        end

        @testset "WebSocket Implementation" begin
            include("websocket_test.jl")
        end

        @testset "Basic Functionality" begin
            include("basic_test.jl")
        end

        @testset "Element Interactions" begin
            include("element_test.jl")
        end

        @testset "Page Operations" begin
            include("page_test.jl")
        end
    finally
        cleanup()
    end
end
