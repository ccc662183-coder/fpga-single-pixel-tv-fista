`timescale 1ns/1ps
// TV dual variable isotropic projection: v / max(1, |v|_2).
// Signed Q5.11 inputs and outputs (ONE=2048). One pixel per transaction.
// Serial integer sqrt and serial unsigned divide for feasible area.
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
    localparam [3:0] IDLE=0, SQRT=1, DIVX_SETUP=2, DIVX=3,
                     DIVY_SETUP=4, DIVY=5, FINISH=6, FINISH_FAST=7;
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
    reg [26:0] dividend;
    reg [31:0] div_rem;
    reg [26:0] div_quot;
    reg [4:0] div_count;
    reg [15:0] quot_x;
    wire [31:0] div_candidate=(div_rem<<1)|{31'd0,dividend[26]};
    wire div_take=(div_candidate >= {16'd0,norm});
    wire [31:0] div_rem_next=div_take ? (div_candidate - {16'd0,norm}) : div_candidate;
    wire [26:0] div_quot_next=(div_quot<<1)|{26'd0,div_take};
    wire [15:0] div_result=(div_quot_next>27'd2048) ? 16'd2048 : div_quot_next[15:0];
    reg [15:0] quot_y;
    always @(posedge clk) begin
        if (!rst_n) begin
            state<=IDLE;valid_out<=0;px_out<=0;py_out<=0;
            sx<=0;sy<=0;ax<=0;ay<=0;
            sqrt_shift<=0;sqrt_remainder<=0;sqrt_root<=0;sqrt_count<=0;
            norm<=0;dividend<=0;div_rem<=0;div_quot<=0;div_count<=0;
            quot_x<=0;quot_y<=0;
        end else begin
            valid_out<=0;
            case(state)
                IDLE: if (start) begin
                    if(sumsquared<=ONE_SQUARED) begin
                        px_out<=vx_in;py_out<=vy_in;
                        state<=FINISH_FAST;
                    end else begin
                        sx<=vx_in[15];sy<=vy_in[15];ax<=abs_x;ay<=abs_y;
                        sqrt_shift<=sumsquared;sqrt_remainder<=0;
                        sqrt_root<=0;sqrt_count<=0;
                        state<=SQRT;
                    end
                end
                SQRT: begin
                    sqrt_root<=sqrt_root_next;
                    sqrt_remainder<=sqrt_rem_next;
                    sqrt_shift<=sqrt_shift<<2;
                    if(sqrt_count==5'd15) begin
                        norm<=sqrt_root_next[15:0];state<=DIVX_SETUP;
                    end else sqrt_count<=sqrt_count+1'b1;
                end
                DIVX_SETUP: begin
                    dividend<=({11'd0,ax}<<11) + ({11'd0,norm}>>1);
                    div_quot<=0;div_rem<=0;div_count<=0;
                    state<=DIVX;
                end
                DIVX: begin
                    dividend<=dividend<<1;div_rem<=div_rem_next;div_quot<=div_quot_next;
                    if(div_count==5'd26) begin
                        quot_x<=div_result;state<=DIVY_SETUP;
                    end else div_count<=div_count+1'b1;
                end
                DIVY_SETUP: begin
                    dividend<=({11'd0,ay}<<11) + ({11'd0,norm}>>1);
                    div_quot<=0;div_rem<=0;div_count<=0;
                    state<=DIVY;
                end
                DIVY: begin
                    dividend<=dividend<<1;div_rem<=div_rem_next;div_quot<=div_quot_next;
                    if(div_count==5'd26) begin
                        quot_y<=div_result;state<=FINISH;
                    end else div_count<=div_count+1'b1;
                end
                FINISH: begin
                    px_out<=sx ? -$signed(quot_x) : $signed(quot_x);
                    py_out<=sy ? -$signed(quot_y) : $signed(quot_y);
                    valid_out<=1'b1;
                    state<=IDLE;
                end
                FINISH_FAST: begin
                    valid_out<=1'b1;
                    state<=IDLE;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
