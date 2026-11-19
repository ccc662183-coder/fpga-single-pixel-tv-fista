
`timescale 1ns / 1ps

// UART RX - local timing optimization V4
// 200 MHz fractional 8N1 receiver
// Original sampling arithmetic is preserved.
// Only successful-frame output is delayed by one clock.

module uart_rx #(
    parameter integer CLK_HZ = 200_000_000,
    parameter integer MIN_CLKS_PER_BIT = 16
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx_i,
    input  wire [26:0] baud_rate,

    output reg  [7:0]  rx_data,
    output reg         rx_valid,
    output reg         rx_frame_error,
    output reg         rx_false_start,
    output wire        rx_busy
);

    localparam [2:0]
        S_IDLE      = 3'd0,
        S_START     = 3'd1,
        S_DATA      = 3'd2,
        S_STOP      = 3'd3,
        S_WAIT_HIGH = 3'd4,
        S_STOP_TAIL = 3'd5;

    localparam [28:0] CLK_HZ_W  = CLK_HZ;
    localparam [28:0] HALF_HZ_W = CLK_HZ / 2;

    localparam integer MAX_BAUD =
        CLK_HZ / MIN_CLKS_PER_BIT;

    localparam [26:0] MAX_BAUD_W = MAX_BAUD;

    reg rx_meta;
    reg rx_sync;
    reg rx_prev;

    reg [2:0]  state;
    reg [7:0]  rx_shift;
    reg [2:0]  bit_index;
    reg [26:0] frame_baud;
    reg [27:0] phase_acc;

    // Output pipeline for a verified STOP bit
    reg stop_ok_pending;

    // ========================================================
    // UART input synchronization
    // ========================================================

    wire rx_fall = rx_prev && !rx_sync;

    wire baud_valid =
        (baud_rate != 27'd0) &&
        (baud_rate <= MAX_BAUD_W);

    // ========================================================
    // Original fractional sampling arithmetic
    // ========================================================

    wire [28:0] phase_sum =
        {1'b0, phase_acc} + {2'b00, frame_baud};

    wire [28:0] phase_limit =
        ((state == S_START) || (state == S_STOP_TAIL))
            ? HALF_HZ_W : CLK_HZ_W;

    wire sample_due = (phase_sum >= phase_limit);

    assign rx_busy = (state != S_IDLE);

    // ========================================================
    // Receiver state machine
    // ========================================================

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            rx_meta         <= 1'b1;
            rx_sync         <= 1'b1;
            rx_prev         <= 1'b1;

            state           <= S_IDLE;
            rx_shift        <= 8'd0;
            bit_index       <= 3'd0;

            frame_baud      <= 27'd0;
            phase_acc       <= 28'd0;

            rx_data         <= 8'd0;
            rx_valid        <= 1'b0;
            rx_frame_error  <= 1'b0;
            rx_false_start  <= 1'b0;

            stop_ok_pending <= 1'b0;

        end
        else begin

            // Two-stage synchronizer and edge detection
            rx_meta <= rx_i;
            rx_sync <= rx_meta;
            rx_prev <= rx_sync;

            // Default single-cycle status pulses
            rx_valid       <= 1'b0;
            rx_frame_error <= 1'b0;
            rx_false_start <= 1'b0;

            stop_ok_pending <= 1'b0;

            // ------------------------------------------------
            // Registered output commit
            //
            // The STOP bit was verified in the previous cycle.
            // rx_shift is held during STOP_TAIL.
            //
            // Thus rx_data and rx_valid update together,
            // one clock after STOP verification.
            // ------------------------------------------------

            if (stop_ok_pending) begin
                rx_data  <= rx_shift;
                rx_valid <= 1'b1;
            end

            case (state)

                // ============================================
                // IDLE
                // ============================================

                S_IDLE: begin

                    phase_acc <= 28'd0;

                    if (rx_fall && baud_valid) begin

                        frame_baud <= baud_rate;
                        bit_index  <= 3'd0;
                        rx_shift   <= 8'd0;

                        state <= S_START;

                    end
                end

                // ============================================
                // START
                // ============================================

                S_START: begin

                    if (sample_due) begin

                        phase_acc <= phase_sum - phase_limit;

                        if (!rx_sync) begin
                            state <= S_DATA;
                        end
                        else begin
                            rx_false_start <= 1'b1;
                            state <= S_IDLE;
                        end

                    end
                    else begin
                        phase_acc <= phase_sum[27:0];
                    end

                end

                // ============================================
                // DATA
                // ============================================

                S_DATA: begin

                    if (sample_due) begin

                        phase_acc <= phase_sum - phase_limit;

                        rx_shift[bit_index] <= rx_sync;

                        if (bit_index == 3'd7) begin
                            state <= S_STOP;
                        end
                        else begin
                            bit_index <= bit_index + 1'b1;
                        end

                    end
                    else begin
                        phase_acc <= phase_sum[27:0];
                    end

                end

                // ============================================
                // STOP
                // ============================================

                S_STOP: begin

                    if (sample_due) begin

                        phase_acc <= phase_sum - phase_limit;

                        if (rx_sync) begin

                            // Do not drive rx_data CE from
                            // the phase comparator directly.

                            stop_ok_pending <= 1'b1;

                            state <= S_STOP_TAIL;

                        end
                        else begin

                            rx_frame_error <= 1'b1;
                            state <= S_WAIT_HIGH;

                        end

                    end
                    else begin
                        phase_acc <= phase_sum[27:0];
                    end

                end

                // ============================================
                // STOP_TAIL
                // ============================================

                S_STOP_TAIL: begin

                    // Preserve gapless 8N1 reception.
                    // A new START edge may arrive while the
                    // current STOP tail is finishing.

                    if (rx_fall && baud_valid) begin

                        frame_baud <= baud_rate;

                        bit_index <= 3'd0;
                        rx_shift  <= 8'd0;
                        phase_acc <= 28'd0;

                        state <= S_START;

                    end
                    else if (sample_due) begin

                        phase_acc <= phase_sum - phase_limit;
                        state <= S_IDLE;

                    end
                    else begin

                        phase_acc <= phase_sum[27:0];

                    end

                end

                // ============================================
                // WAIT_HIGH
                // ============================================

                S_WAIT_HIGH: begin

                    phase_acc <= 28'd0;

                    if (rx_sync)
                        state <= S_IDLE;

                end

                default: begin

                    phase_acc <= 28'd0;
                    state <= S_IDLE;

                end

            endcase

        end

    end

endmodule
