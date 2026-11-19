
`timescale 1ns / 1ps

// Timing-optimized UART 8N1 transmitter.
// Fractional accumulator with registered baud threshold.
// Ready/valid interface remains unchanged.

module uart_tx #(
    parameter integer CLK_HZ = 200_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [26:0] baud_rate,
    input  wire [7:0]  tx_data,
    input  wire        tx_valid,
    output wire        tx_ready,
    output reg         tx_o,
    output wire        tx_busy,
    output reg         tx_done
);

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_START = 2'd1;
    localparam [1:0] S_DATA  = 2'd2;
    localparam [1:0] S_STOP  = 2'd3;

    localparam [28:0] CLK_HZ_W = CLK_HZ;
    localparam [27:0] CLK_HZ_28 = CLK_HZ;

    reg [1:0] state;
    reg [7:0] shift_reg;
    reg [2:0] bit_index;

    reg [26:0] frame_baud;
    reg [27:0] frame_threshold;
    reg [27:0] phase_acc;

    // Threshold for the next selected baud.
    wire [27:0] requested_threshold =
        CLK_HZ_28 - {1'b0, baud_rate};

    // Fractional phase arithmetic.
    // The two candidates are computed in parallel.
    wire boundary_due =
        (phase_acc >= frame_threshold);

    wire [27:0] phase_advance =
        phase_acc + {1'b0, frame_baud};

    wire [27:0] phase_wrap =
        phase_acc - frame_threshold;

    wire baud_valid =
        (baud_rate != 27'd0) &&
        ({2'b00, baud_rate} < CLK_HZ_W);

    // Allow zero-extra-gap continuous transmission.
    assign tx_ready =
        rst_n && baud_valid &&
        (
            (state == S_IDLE) ||
            ((state == S_STOP) && boundary_due)
        );

    assign tx_busy = (state != S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            shift_reg       <= 8'd0;
            bit_index       <= 3'd0;
            frame_baud      <= 27'd0;
            frame_threshold <= CLK_HZ_28;
            phase_acc       <= 28'd0;
            tx_o            <= 1'b1;
            tx_done         <= 1'b0;
        end
        else begin
            tx_done <= 1'b0;

            if (state == S_IDLE) begin
                tx_o      <= 1'b1;
                phase_acc <= 28'd0;

                if (tx_valid && tx_ready) begin
                    shift_reg       <= tx_data;
                    bit_index       <= 3'd0;
                    frame_baud      <= baud_rate;
                    frame_threshold <= requested_threshold;
                    phase_acc       <= 28'd0;
                    tx_o            <= 1'b0;
                    state           <= S_START;
                end
            end
            else begin

                // Parallel candidate selection.
                if (boundary_due)
                    phase_acc <= phase_wrap;
                else
                    phase_acc <= phase_advance;

                if (boundary_due) begin
                    case (state)

                        S_START: begin
                            tx_o      <= shift_reg[0];
                            shift_reg <= {
                                1'b0, shift_reg[7:1]
                            };
                            bit_index <= 3'd0;
                            state     <= S_DATA;
                        end

                        S_DATA: begin
                            if (bit_index == 3'd7) begin
                                tx_o  <= 1'b1;
                                state <= S_STOP;
                            end
                            else begin
                                tx_o      <= shift_reg[0];
                                shift_reg <= {
                                    1'b0, shift_reg[7:1]
                                };
                                bit_index <= bit_index + 3'd1;
                            end
                        end

                        S_STOP: begin
                            tx_done <= 1'b1;

                            if (tx_valid && tx_ready) begin
                                shift_reg <= tx_data;
                                bit_index <= 3'd0;

                                // Preserve fractional phase
                                // when consecutive frames use
                                // the same baud rate.
                                if (baud_rate != frame_baud) begin
                                    phase_acc <= 28'd0;
                                    frame_threshold <=
                                        requested_threshold;
                                end

                                frame_baud <= baud_rate;
                                tx_o       <= 1'b0;
                                state      <= S_START;
                            end
                            else begin
                                tx_o  <= 1'b1;
                                state <= S_IDLE;
                            end
                        end

                        default: begin
                            tx_o  <= 1'b1;
                            state <= S_IDLE;
                        end

                    endcase
                end
            end
        end
    end

endmodule
