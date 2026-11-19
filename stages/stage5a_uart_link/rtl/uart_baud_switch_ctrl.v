
`timescale 1ns / 1ps

// Runtime UART baud-rate negotiation controller.
// This module accepts DECODED commands, not raw UART bytes.
// An external protocol core is responsible for packet parsing,
// response payload assembly, arbitration, and data-path draining.
module uart_baud_switch_ctrl #(
    parameter [26:0] DEFAULT_BAUD = 27'd1000000,
    parameter [26:0] MIN_BAUD     = 27'd300,
    parameter [26:0] MAX_BAUD     = 27'd10000000,

    // Defaults refer to the 200 MHz application clock.
    parameter integer GUARD_CYCLES           = 400000,
    parameter integer DRAIN_TIMEOUT_CYCLES   = 20000000,
    parameter integer PREP_TIMEOUT_CYCLES    = 400000000,
    parameter integer CONFIRM_TIMEOUT_CYCLES = 400000000,
    parameter integer RESP_TIMEOUT_CYCLES    = 400000000
)(
    input  wire        clk,
    input  wire        rst_n,

    // Decoded command interface
    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire [7:0]  cmd_type,
    input  wire [15:0] cmd_seq,
    input  wire [8:0]  cmd_len,
    input  wire [31:0] cmd_baud,

    // Response request interface
    output wire        resp_valid,
    input  wire        resp_ready,
    output reg  [7:0]  resp_type,
    output reg  [15:0] resp_seq,
    output reg  [8:0]  resp_len,
    output reg  [31:0] resp_value,
    input  wire        resp_done,

    // Complete communication pipeline idle
    input  wire        link_idle,

    // Active UART configuration
    output reg  [26:0] active_baud,
    output reg         baud_changed,
    output reg         rollback_pulse,
    output reg         link_flush,
    output wire        switch_pending,

    // Diagnostics
    output reg  [31:0] timeout_count,
    output reg  [31:0] rejected_count
);

    // =====================================================
    // 1. Protocol command definitions
    // =====================================================

    localparam [7:0]
        C_GET_STATUS   = 8'h10,
        C_STATUS_RESP  = 8'h11,
        C_PREPARE      = 8'h30,
        C_READY        = 8'h31,
        C_COMMIT       = 8'h32,
        C_COMMIT_ACK   = 8'h33,
        C_CONFIRM      = 8'h34,
        C_BAUD_OK      = 8'h35,
        C_ABORT        = 8'h36,
        C_ERROR        = 8'h3F;

    // =====================================================
    // 2. Controller states
    // =====================================================

    localparam [2:0]
        S_IDLE         = 3'd0,
        S_RESP_REQ     = 3'd1,
        S_RESP_DONE    = 3'd2,
        S_PREPARED     = 3'd3,
        S_GUARD        = 3'd4,
        S_WAIT_CONFIRM = 3'd5;

    localparam [1:0]
        AFTER_IDLE     = 2'd0,
        AFTER_PREPARED = 2'd1,
        AFTER_GUARD    = 2'd2,
        AFTER_SUCCESS  = 2'd3;

    reg [2:0]  state;
    reg [1:0]  after_response;
    reg [31:0] timer;

    // Transaction registers
    reg [26:0] candidate_baud;
    reg [26:0] previous_baud;
    reg [15:0] transaction_seq;

    // =====================================================
    // 3. Configuration validation
    // =====================================================

    wire good_baud =
        (cmd_baud >= {5'b0, MIN_BAUD}) &&
        (cmd_baud <= {5'b0, MAX_BAUD});

    // =====================================================
    // 4. Interface handshakes
    // =====================================================

    assign cmd_ready = rst_n &&
        (
            (state == S_IDLE) ||
            (state == S_PREPARED) ||
            (state == S_WAIT_CONFIRM)
        );

    assign resp_valid =
        rst_n && (state == S_RESP_REQ);

    assign switch_pending =
        (state == S_PREPARED) ||
        (state == S_GUARD) ||
        (state == S_WAIT_CONFIRM) ||
        (
            (
                (state == S_RESP_REQ) ||
                (state == S_RESP_DONE)
            ) &&
            (after_response != AFTER_IDLE)
        );

    // =====================================================
    // 5. Main state machine
    // =====================================================

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            state           <= S_IDLE;
            after_response  <= AFTER_IDLE;
            timer           <= 32'd0;

            candidate_baud  <= DEFAULT_BAUD;
            previous_baud   <= DEFAULT_BAUD;
            transaction_seq <= 16'd0;
            active_baud     <= DEFAULT_BAUD;

            resp_type       <= 8'd0;
            resp_seq        <= 16'd0;
            resp_len        <= 9'd0;
            resp_value      <= 32'd0;

            baud_changed    <= 1'b0;
            rollback_pulse  <= 1'b0;
            link_flush      <= 1'b0;

            timeout_count   <= 32'd0;
            rejected_count  <= 32'd0;

        end
        else begin

            // Pulse outputs are cleared by default.
            baud_changed   <= 1'b0;
            rollback_pulse <= 1'b0;
            link_flush     <= 1'b0;

            case (state)

                // =========================================
                // IDLE
                // =========================================

                S_IDLE: begin

                    timer <= 32'd0;

                    if (cmd_valid && cmd_ready) begin

                        resp_seq <= cmd_seq;

                        // Query current baud rate
                        if (
                            (cmd_type == C_GET_STATUS) &&
                            (cmd_len == 9'd0)
                        ) begin

                            resp_type  <= C_STATUS_RESP;
                            resp_len   <= 9'd4;
                            resp_value <= {5'd0, active_baud};

                            after_response <= AFTER_IDLE;

                        end

                        // Prepare a new baud rate
                        else if (
                            (cmd_type == C_PREPARE) &&
                            (cmd_len == 9'd4) &&
                            good_baud
                        ) begin

                            previous_baud <= active_baud;
                            candidate_baud <= cmd_baud[26:0];
                            transaction_seq <= cmd_seq;

                            resp_type  <= C_READY;
                            resp_len   <= 9'd4;
                            resp_value <= cmd_baud;

                            after_response <= AFTER_PREPARED;

                        end

                        // Unsupported or illegal request
                        else begin

                            rejected_count <=
                                rejected_count + 1'b1;

                            resp_type  <= C_ERROR;
                            resp_len   <= 9'd1;
                            resp_value <= 32'h00000001;

                            after_response <= AFTER_IDLE;

                        end

                        state <= S_RESP_REQ;

                    end
                end

                // =========================================
                // PREPARED
                //
                // Waiting for COMMIT or ABORT.
                // The active UART baud does not change.
                // =========================================

                S_PREPARED: begin

                    if (
                        timer >= PREP_TIMEOUT_CYCLES - 1
                    ) begin

                        timeout_count <= timeout_count + 1'b1;
                        timer <= 32'd0;
                        state <= S_IDLE;

                    end

                    else if (cmd_valid && cmd_ready) begin

                        timer <= 32'd0;
                        resp_seq <= cmd_seq;

                        if (
                            (cmd_type == C_COMMIT) &&
                            (cmd_len == 9'd0) &&
                            (cmd_seq == transaction_seq)
                        ) begin

                            resp_type <= C_COMMIT_ACK;
                            resp_len <= 9'd4;
                            resp_value <= {5'd0, active_baud};

                            after_response <= AFTER_GUARD;

                        end

                        else if (
                            (cmd_type == C_ABORT) &&
                            (cmd_len == 9'd0) &&
                            (cmd_seq == transaction_seq)
                        ) begin

                            resp_type <= C_ABORT;
                            resp_len <= 9'd0;
                            resp_value <= 32'd0;

                            after_response <= AFTER_IDLE;

                        end

                        else begin

                            rejected_count <=
                                rejected_count + 1'b1;

                            resp_type <= C_ERROR;
                            resp_len <= 9'd1;
                            resp_value <= 32'h00000002;

                            after_response <= AFTER_PREPARED;

                        end

                        state <= S_RESP_REQ;

                    end

                    else begin

                        timer <= timer + 1'b1;

                    end
                end

                // =========================================
                // RESPONSE REQUEST
                //
                // Wait until the packet transmitter accepts
                // this response request.
                // =========================================

                S_RESP_REQ: begin

                    if (resp_ready && resp_valid) begin

                        timer <= 32'd0;
                        state <= S_RESP_DONE;

                    end

                    else if (
                        timer >= RESP_TIMEOUT_CYCLES - 1
                    ) begin

                        timer <= 32'd0;
                        timeout_count <= timeout_count + 1'b1;
                        link_flush <= 1'b1;

                        if (
                            after_response == AFTER_SUCCESS
                        ) begin

                            active_baud <= previous_baud;
                            baud_changed <= 1'b1;
                            rollback_pulse <= 1'b1;

                        end

                        state <= S_IDLE;

                    end

                    else begin

                        timer <= timer + 1'b1;

                    end
                end

                // =========================================
                // RESPONSE COMPLETION
                //
                // resp_done must mean the final UART frame
                // of this packet has physically completed.
                // =========================================

                S_RESP_DONE: begin

                    if (resp_done) begin

                        timer <= 32'd0;

                        case (after_response)

                            AFTER_PREPARED:
                                state <= S_PREPARED;

                            AFTER_GUARD:
                                state <= S_GUARD;

                            default:
                                state <= S_IDLE;

                        endcase

                    end

                    else if (
                        timer >= RESP_TIMEOUT_CYCLES - 1
                    ) begin

                        timer <= 32'd0;
                        timeout_count <= timeout_count + 1'b1;
                        link_flush <= 1'b1;

                        if (
                            after_response == AFTER_SUCCESS
                        ) begin

                            active_baud <= previous_baud;
                            baud_changed <= 1'b1;
                            rollback_pulse <= 1'b1;

                        end

                        state <= S_IDLE;

                    end

                    else begin

                        timer <= timer + 1'b1;

                    end
                end

                // =========================================
                // GUARD INTERVAL
                //
                // The COMMIT_ACK packet is fully transmitted.
                // Wait for the protected interval and for
                // the entire communication link to drain.
                // =========================================

                S_GUARD: begin

                    if (
                        (timer >= GUARD_CYCLES - 1) &&
                        link_idle
                    ) begin

                        active_baud <= candidate_baud;
                        baud_changed <= 1'b1;
                        link_flush <= 1'b1;

                        timer <= 32'd0;
                        state <= S_WAIT_CONFIRM;

                    end

                    else if (
                        timer >= DRAIN_TIMEOUT_CYCLES - 1
                    ) begin

                        // No baud change has occurred.
                        timeout_count <= timeout_count + 1'b1;

                        timer <= 32'd0;
                        state <= S_IDLE;

                    end

                    else begin

                        timer <= timer + 1'b1;

                    end
                end

                // =========================================
                // WAIT FOR CONFIRMATION
                //
                // The UART is now using the target baud.
                // Without confirmation, restore old baud.
                // =========================================

                S_WAIT_CONFIRM: begin

                    if (
                        timer >= CONFIRM_TIMEOUT_CYCLES - 1
                    ) begin

                        active_baud <= previous_baud;

                        baud_changed <= 1'b1;
                        rollback_pulse <= 1'b1;
                        link_flush <= 1'b1;

                        timeout_count <= timeout_count + 1'b1;

                        timer <= 32'd0;
                        state <= S_IDLE;

                    end

                    else if (cmd_valid && cmd_ready) begin

                        if (
                            (cmd_type == C_CONFIRM) &&
                            (cmd_seq == transaction_seq) &&
                            (cmd_len == 9'd4) &&
                            (
                                cmd_baud ==
                                {5'd0, candidate_baud}
                            )
                        ) begin

                            resp_type <= C_BAUD_OK;
                            resp_seq <= transaction_seq;
                            resp_len <= 9'd4;
                            resp_value <= {5'd0, active_baud};

                            after_response <= AFTER_SUCCESS;

                            timer <= 32'd0;
                            state <= S_RESP_REQ;

                        end

                        else begin

                            // Ignore unrelated packets during
                            // the new-baud negotiation window.

                            rejected_count <=
                                rejected_count + 1'b1;

                            timer <= timer + 1'b1;

                        end

                    end

                    else begin

                        timer <= timer + 1'b1;

                    end
                end

                // =========================================
                // Invalid state recovery
                // =========================================

                default: begin

                    timer <= 32'd0;
                    state <= S_IDLE;

                end

            endcase
        end
    end

endmodule

