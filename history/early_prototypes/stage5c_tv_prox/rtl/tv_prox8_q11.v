`timescale 1ns/1ps
// Small-image fixed-point TV proximal inner-loop demonstrator, 8x8 pixels.
// Q5.11 pixels/dual; lambda=20/2048; Jacobi dual update, 3 inner steps.
// Uses previously tested tv_dual_project_q11 as the non-linear primitive.
// V3: V2 projector input pipeline PLUS staged divergence/weight/final write.
// Timing target: cut p_x register -> dynamic mux -> *20 -> final_mem path.
// Split both u_mem and final_mem updates through a common three-stage pipe.
// IMPORTANT: 8x8 register-array DEMO only, NOT a BRAM/128x128 architecture.
module tv_prox8_q11 (
    input wire clk,
    input wire rst_n,
    input wire load_we,
    input wire [5:0] load_addr,
    input wire signed [15:0] load_data,
    input wire start,
    output wire ready,
    output reg done,
    input wire [5:0] read_addr,
    output wire signed [15:0] read_data
);
    localparam [3:0] S_IDLE=0, S_CALC_U=1, S_FETCH=2, S_GRAD=3,
                     S_DIV_INIT=4, S_DIV_RUN=5, S_SET_V=6,
                     S_PROJ_START=7, S_PROJ_WAIT=8, S_COMMIT=9,
                     S_FINAL=10, S_DONE=11,
                     S_U_READ=12, S_U_DIV=13, S_U_WEIGHT=14;
    reg [3:0] state;
    reg [5:0] index;
    reg [1:0] iteration;
    reg final_phase;
    reg signed [15:0] f_mem [0:63];
    reg signed [15:0] u_mem [0:63];
    reg signed [15:0] p_x [0:63];
    reg signed [15:0] p_y [0:63];
    reg signed [15:0] pn_x [0:63];
    reg signed [15:0] pn_y [0:63];
    reg signed [15:0] final_mem [0:63];
    integer j;
    wire last_row=(index[5:3]==3'd7);
    wire last_col=(index[2:0]==3'd7);
    wire first_row=(index[5:3]==3'd0);
    wire first_col=(index[2:0]==3'd0);

    // Pipelined TV divergence and scaled image update, shared by
    // S_CALC_U (work image) and S_FINAL (final image).  The integer
    // expression is identical to V2, with registered intermediate results.
    reg signed [15:0] f_hold, px_hold, py_hold, px_prev_hold, py_prev_hold;
    reg signed [17:0] div_hold;
    reg signed [31:0] weighted_hold;
    wire signed [31:0] new_u_wide =
        $signed(f_hold) + ($signed(weighted_hold) >>> 11);
    // Break original u_mem -> gradient -> /20 -> multiplication path.
    // FETCH: register indexed memory outputs.
    // GRAD: register differences.
    // DIV_RUN: exact, two parallel unsigned serial divisions by 5.
    // SET_V: add p and register projection input; no computation before
    // the nonlinear projector's input multipliers in the same cycle.
    reg signed [15:0] u_here, u_below, u_right, px_here, py_here;
    reg signed [17:0] grad_x_q, grad_y_q;
    reg gx_neg, gy_neg;
    reg [23:0] dividend_x, dividend_y, quotient_x, quotient_y;
    reg [3:0] rem_x, rem_y;
    reg [4:0] div_count;
    reg signed [15:0] vx_q, vy_q;

    wire [17:0] abs_grad_x = grad_x_q[17] ? -grad_x_q : grad_x_q;
    wire [17:0] abs_grad_y = grad_y_q[17] ? -grad_y_q : grad_y_q;
    // grad*256 / 20 = grad*64 / 5, with signed truncation toward zero.
    // unsigned long-division processes 24 bits, including leading zeroes.
    wire [3:0] trial_x = {rem_x[2:0], dividend_x[23]};
    wire [3:0] trial_y = {rem_y[2:0], dividend_y[23]};
    wire take_x = (trial_x >= 4'd5);
    wire take_y = (trial_y >= 4'd5);
    wire [3:0] next_rem_x = take_x ? trial_x - 4'd5 : trial_x;
    wire [3:0] next_rem_y = take_y ? trial_y - 4'd5 : trial_y;
    wire [23:0] next_quo_x = {quotient_x[22:0], take_x};
    wire [23:0] next_quo_y = {quotient_y[22:0], take_y};
    wire signed [31:0] delta_x = gx_neg ? -$signed({8'd0, quotient_x}) : $signed({8'd0, quotient_x});
    wire signed [31:0] delta_y = gy_neg ? -$signed({8'd0, quotient_y}) : $signed({8'd0, quotient_y});

    wire proj_start = (state==S_PROJ_START);
    wire proj_ready,proj_valid;
    wire signed [15:0] proj_x,proj_y;
    tv_dual_project_q11 projection (
      .clk(clk), .rst_n(rst_n),.start(proj_start),
      .vx_in(vx_q),.vy_in(vy_q),
      .ready(proj_ready),.valid_out(proj_valid),.px_out(proj_x),.py_out(proj_y)
    );
    assign ready=(state==S_IDLE);
    assign read_data=final_mem[read_addr];
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=S_IDLE;done<=0;index<=0;iteration<=0;final_phase<=0;
            f_hold<=0;px_hold<=0;py_hold<=0;px_prev_hold<=0;py_prev_hold<=0;
            div_hold<=0;weighted_hold<=0;
            u_here<=0;u_below<=0;u_right<=0;px_here<=0;py_here<=0;
            grad_x_q<=0;grad_y_q<=0;gx_neg<=0;gy_neg<=0;
            dividend_x<=0;dividend_y<=0;quotient_x<=0;quotient_y<=0;
            rem_x<=0;rem_y<=0;div_count<=0;vx_q<=0;vy_q<=0;
            for(j=0;j<64;j=j+1) begin
                f_mem[j]<=0;u_mem[j]<=0;p_x[j]<=0;p_y[j]<=0;
                pn_x[j]<=0;pn_y[j]<=0;final_mem[j]<=0;
            end
        end else begin
            done<=0;
            if(load_we && state==S_IDLE) f_mem[load_addr]<=load_data;
            case(state)
                S_IDLE: if(start && !load_we) begin
                    index<=0;iteration<=0;final_phase<=0;
                    // Fresh p for every transaction.
                    for(j=0;j<64;j=j+1) begin
                        p_x[j]<=0;p_y[j]<=0;pn_x[j]<=0;pn_y[j]<=0;
                    end
                    state<=S_U_READ;
                end
                // Stage 1: register all memory data, including boundary clamping.
                // This removes the combinational array-select delay from the
                // subsequent arithmetic/multiplication stages.
                S_U_READ: begin
                    f_hold <= f_mem[index];
                    px_hold <= p_x[index];
                    py_hold <= p_y[index];
                    px_prev_hold <= first_row ? 16'sd0 : p_x[index-6'd8];
                    py_prev_hold <= first_col ? 16'sd0 : p_y[index-6'd1];
                    state <= S_U_DIV;
                end
                // Stage 2: Q11 signed divergence with extra headroom.
                S_U_DIV: begin
                    div_hold <= $signed(px_hold) + $signed(py_hold)
                              - $signed(px_prev_hold) - $signed(py_prev_hold);
                    state <= S_U_WEIGHT;
                end
                // Stage 3: exact multiplication by the Q11 TV constant.
                S_U_WEIGHT: begin
                    weighted_hold <= $signed(div_hold) * 32'sd20;
                    state <= final_phase ? S_FINAL : S_CALC_U;
                end
                S_CALC_U: begin
                    u_mem[index]<=new_u_wide[15:0];
                    if(index==6'd63) begin index<=0;state<=S_FETCH;end
                    else begin index<=index+1'b1;state<=S_U_READ;end
                end
                S_FETCH: begin
                    u_here<=u_mem[index];
                    u_below<=last_row ? 16'sd0 : u_mem[index+6'd8];
                    u_right<=last_col ? 16'sd0 : u_mem[index+6'd1];
                    px_here<=p_x[index];
                    py_here<=p_y[index];
                    state<=S_GRAD;
                end
                S_GRAD: begin
                    grad_x_q<=last_row ? 18'sd0 : ($signed(u_below)-$signed(u_here));
                    grad_y_q<=last_col ? 18'sd0 : ($signed(u_right)-$signed(u_here));
                    state<=S_DIV_INIT;
                end
                S_DIV_INIT: begin
                    gx_neg<=grad_x_q[17];
                    gy_neg<=grad_y_q[17];
                    dividend_x<={abs_grad_x, 6'b0};
                    dividend_y<={abs_grad_y, 6'b0};
                    quotient_x<=0;quotient_y<=0;
                    rem_x<=0;rem_y<=0;div_count<=0;
                    state<=S_DIV_RUN;
                end
                S_DIV_RUN: begin
                    dividend_x<=dividend_x<<1;
                    dividend_y<=dividend_y<<1;
                    quotient_x<=next_quo_x;
                    quotient_y<=next_quo_y;
                    rem_x<=next_rem_x;
                    rem_y<=next_rem_y;
                    if(div_count==5'd23) state<=S_SET_V;
                    else div_count<=div_count+1'b1;
                end
                S_SET_V: begin
                    vx_q<=last_row ? 16'sd0 : ($signed(px_here)+delta_x);
                    vy_q<=last_col ? 16'sd0 : ($signed(py_here)+delta_y);
                    state<=S_PROJ_START;
                end
                S_PROJ_START: if(proj_ready) state<=S_PROJ_WAIT;
                S_PROJ_WAIT: if(proj_valid) begin
                    pn_x[index]<=proj_x;
                    pn_y[index]<=proj_y;
                    if(index==6'd63) begin index<=0;state<=S_COMMIT;end
                    else begin index<=index+1'b1;state<=S_FETCH;end
                end
                S_COMMIT: begin
                    p_x[index]<=pn_x[index];
                    p_y[index]<=pn_y[index];
                    if(index==6'd63) begin
                        index<=0;
                        if(iteration==2) begin final_phase<=1;state<=S_U_READ;end
                        else begin iteration<=iteration+1'b1;state<=S_U_READ;end
                    end else index<=index+1'b1;
                end
                S_FINAL: begin
                    final_mem[index]<=new_u_wide[15:0];
                    if(index==6'd63) begin state<=S_DONE;index<=0;end
                    else begin index<=index+1'b1;state<=S_U_READ;end
                end
                S_DONE: begin done<=1;state<=S_IDLE;end
                default: state<=S_IDLE;
            endcase
        end
    end
endmodule
