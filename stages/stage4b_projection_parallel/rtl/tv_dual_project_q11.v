`timescale 1ns/1ps
// TV dual variable isotropic projection: v / max(1, |v|_2).
// Signed Q5.11 inputs and outputs (ONE=2048). One pixel per transaction.
// Serial integer sqrt; parallel radix-8 unsigned dividers (X/Y).
// This module is only the nonlinear projection primitive, NOT full TV-FISTA.
module tv_dual_project_q11 (
    input wire clk, input wire rst_n,
    input wire start,
    input wire signed [15:0] vx_in, input wire signed [15:0] vy_in,
    output wire ready,
    output reg valid_out,
    output reg signed [15:0] px_out, output reg signed [15:0] py_out
);
    localparam [31:0] ONE_SQUARED = 32'd4194304; // (2^11)^2
    localparam [3:0] IDLE=4'd0, SQRT=4'd1, DIV_SETUP=4'd2,
                     DIV_PARALLEL=4'd3, FINISH=4'd4, FINISH_FAST=4'd5;
    reg [3:0] state;
    assign ready=(state==IDLE);
    wire signed [31:0] x2 = $signed(vx_in)*$signed(vx_in);
    wire signed [31:0] y2 = $signed(vy_in)*$signed(vy_in);
    wire [31:0] sumsquared = $unsigned(x2)+$unsigned(y2);
    wire [15:0] abs_x = vx_in[15] ? (~vx_in + 16'd1) : vx_in;
    wire [15:0] abs_y = vy_in[15] ? (~vy_in + 16'd1) : vy_in;
    reg sx,sy;
    reg [15:0] ax, ay;
    reg [31:0] sqrt_shift;
    reg [33:0] sqrt_remainder;
    reg [16:0] sqrt_root;
    reg [4:0] sqrt_count;
    wire [33:0] sqrt_cand = (sqrt_remainder << 2) | {32'd0,sqrt_shift[31:30]};
    wire [33:0] sqrt_trial = ({17'd0,sqrt_root} << 2) | 34'd1;
    wire sqrt_take=(sqrt_cand>=sqrt_trial);
    wire [16:0] sqrt_root_next = (sqrt_root << 1) | {16'd0,sqrt_take};
    wire [33:0] sqrt_rem_next = sqrt_take ? (sqrt_cand - sqrt_trial) : sqrt_cand;
    reg [15:0] norm;
    // Stage-4B: both unsigned 27-bit divisions run concurrently, radix-8.
    // Each cycle consumes 3 source bits. Remainder and quotient are updated
    // by three combinational bit steps exactly matching the serial reference.
    reg [26:0] dividend_x, dividend_y;
    reg [31:0] div_rem_x, div_rem_y;
    reg [26:0] div_quot_x, div_quot_y;
    reg [3:0]  div_count;
    reg [15:0] quot_x, quot_y;

    // X axis: one three-bit division group.
    wire [31:0] div_trial_x0 = (div_rem_x << 1) |
        {31'd0, dividend_x[26]};
    wire div_take_x0 = (div_trial_x0 >= {16'd0, norm});
    wire [31:0] div_rem_x1 = div_take_x0 ?
        (div_trial_x0 - {16'd0, norm}) : div_trial_x0;
    wire [31:0] div_trial_x1 = (div_rem_x1 << 1) |
        {31'd0, dividend_x[25]};
    wire div_take_x1 = (div_trial_x1 >= {16'd0, norm});
    wire [31:0] div_rem_x2 = div_take_x1 ?
        (div_trial_x1 - {16'd0, norm}) : div_trial_x1;
    wire [31:0] div_trial_x2 = (div_rem_x2 << 1) |
        {31'd0, dividend_x[24]};
    wire div_take_x2 = (div_trial_x2 >= {16'd0, norm});
    wire [31:0] div_rem_x3 = div_take_x2 ?
        (div_trial_x2 - {16'd0, norm}) : div_trial_x2;
    wire [31:0] div_rem_x_next = div_rem_x3;
    wire [26:0] div_quot_x_next = (div_quot_x << 3) |
        {24'd0, div_take_x0, div_take_x1, div_take_x2};
    wire [15:0] div_result_x =
        (div_quot_x_next > 27'd2048) ? 16'd2048 : div_quot_x_next[15:0];

    // Y axis: one three-bit division group.
    wire [31:0] div_trial_y0 = (div_rem_y << 1) |
        {31'd0, dividend_y[26]};
    wire div_take_y0 = (div_trial_y0 >= {16'd0, norm});
    wire [31:0] div_rem_y1 = div_take_y0 ?
        (div_trial_y0 - {16'd0, norm}) : div_trial_y0;
    wire [31:0] div_trial_y1 = (div_rem_y1 << 1) |
        {31'd0, dividend_y[25]};
    wire div_take_y1 = (div_trial_y1 >= {16'd0, norm});
    wire [31:0] div_rem_y2 = div_take_y1 ?
        (div_trial_y1 - {16'd0, norm}) : div_trial_y1;
    wire [31:0] div_trial_y2 = (div_rem_y2 << 1) |
        {31'd0, dividend_y[24]};
    wire div_take_y2 = (div_trial_y2 >= {16'd0, norm});
    wire [31:0] div_rem_y3 = div_take_y2 ?
        (div_trial_y2 - {16'd0, norm}) : div_trial_y2;
    wire [31:0] div_rem_y_next = div_rem_y3;
    wire [26:0] div_quot_y_next = (div_quot_y << 3) |
        {24'd0, div_take_y0, div_take_y1, div_take_y2};
    wire [15:0] div_result_y =
        (div_quot_y_next > 27'd2048) ? 16'd2048 : div_quot_y_next[15:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            valid_out <= 1'b0;
            px_out <= 16'sd0;
            py_out <= 16'sd0;
            sx <= 1'b0; sy <= 1'b0; ax <= 16'd0; ay <= 16'd0;
            sqrt_shift <= 32'd0;
            sqrt_remainder <= 34'd0;
            sqrt_root <= 17'd0;
            sqrt_count <= 5'd0;
            norm <= 16'd0;
            dividend_x <= 27'd0; dividend_y <= 27'd0;
            div_rem_x <= 32'd0; div_rem_y <= 32'd0;
            div_quot_x <= 27'd0; div_quot_y <= 27'd0;
            div_count <= 4'd0;
            quot_x <= 16'd0; quot_y <= 16'd0;
        end else begin
            valid_out <= 1'b0;
            case (state)
                IDLE: if (start) begin
                    // Fast path is byte-for-byte equivalent to Stage-4A.
                    if (sumsquared <= ONE_SQUARED) begin
                        px_out <= vx_in;
                        py_out <= vy_in;
                        state <= FINISH_FAST;
                    end else begin
                        sx <= vx_in[15]; sy <= vy_in[15];
                        ax <= abs_x; ay <= abs_y;
                        sqrt_shift <= sumsquared;
                        sqrt_remainder <= 34'd0;
                        sqrt_root <= 17'd0;
                        sqrt_count <= 5'd0;
                        state <= SQRT;
                    end
                end
                SQRT: begin
                    sqrt_root <= sqrt_root_next;
                    sqrt_remainder <= sqrt_rem_next;
                    sqrt_shift <= sqrt_shift << 2;
                    if (sqrt_count == 5'd15) begin
                        norm <= sqrt_root_next[15:0];
                        state <= DIV_SETUP;
                    end else begin
                        sqrt_count <= sqrt_count + 1'b1;
                    end
                end
                DIV_SETUP: begin
                    // Preserve Stage-4A rounding: (abs(v)<<11)+(norm>>1).
                    dividend_x <= ({11'd0, ax} << 11) + ({11'd0, norm} >> 1);
                    dividend_y <= ({11'd0, ay} << 11) + ({11'd0, norm} >> 1);
                    div_quot_x <= 27'd0; div_quot_y <= 27'd0;
                    div_rem_x <= 32'd0; div_rem_y <= 32'd0;
                    div_count <= 4'd0;
                    state <= DIV_PARALLEL;
                end
                DIV_PARALLEL: begin
                    dividend_x <= dividend_x << 3;
                    dividend_y <= dividend_y << 3;
                    div_rem_x <= div_rem_x_next;
                    div_rem_y <= div_rem_y_next;
                    div_quot_x <= div_quot_x_next;
                    div_quot_y <= div_quot_y_next;
                    if (div_count == 4'd8) begin
                        quot_x <= div_result_x;
                        quot_y <= div_result_y;
                        state <= FINISH;
                    end else begin
                        div_count <= div_count + 1'b1;
                    end
                end
                FINISH: begin
                    px_out <= sx ? -$signed(quot_x) : $signed(quot_x);
                    py_out <= sy ? -$signed(quot_y) : $signed(quot_y);
                    valid_out <= 1'b1;
                    state <= IDLE;
                end
                FINISH_FAST: begin
                    valid_out <= 1'b1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
