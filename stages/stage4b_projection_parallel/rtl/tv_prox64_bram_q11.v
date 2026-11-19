`timescale 1ns/1ps
// 64x64 BRAM-based TV proximal engine, Q5.11.
// Algorithm and integer operations match stage0_2_fixedpoint.py / Stage-5C:
//   div = px + py - px_up - py_left
//   u   = f + ((div * 20) >>> 11)
//   gx  = u_down - u; gy = u_right - u
//   delta = trunc_toward_zero(grad * 64 / 5)
//   (px_new,py_new) = isotropic_project(px+delta_x,py+delta_y)
// All dual updates are Jacobi: pn_x/pn_y are committed only after a full image pass.
//
// Memory organization:
//   f_mem, u_mem, px_mem, py_mem, pnx_mem, pny_mem: 6 x 4096x16 SP BRAM
//   out_mem: 1 x 4096x16 simple-dual-port BRAM
// Estimated storage: 7 * 65536 = 458752 bits (~14 RAMB36).
//
// This is the standalone TV Prox block only. It does not include FWHT,
// FISTA outer iterations, UART, or a board-level top module.
module tv_prox64_bram_q11 #(
    parameter integer INNER_STEPS = 35
) (
    input  wire        clk,
    input  wire        rst_n,

    // Load one 64x64 input image in row-major order, signed Q5.11.
    input  wire        load_we,
    input  wire [11:0] load_addr,
    input  wire signed [15:0] load_data,

    // Start one 35-step TV Prox transaction after all 4096 pixels are loaded.
    input  wire        start,
    output wire        ready,
    output wire        busy,
    output reg         done,

    // Synchronous result read port; read_valid is asserted one cycle after read_en.
    input  wire        read_en,
    input  wire [11:0] read_addr,
    output reg         read_valid,
    output wire [15:0] read_data
);
    localparam [5:0]
        S_IDLE             = 6'd0,
        S_INIT             = 6'd1,
        S_U_READ_CUR       = 6'd2,
        S_U_READ_PREV      = 6'd3,
        S_U_CAPTURE_PREV   = 6'd4,
        S_U_DIV            = 6'd5,
        S_U_WEIGHT         = 6'd6,
        S_U_WRITE          = 6'd7,
        S_G_READ_HERE      = 6'd8,
        S_G_READ_BELOW     = 6'd9,
        S_G_READ_RIGHT     = 6'd10,
        S_G_CAPTURE_RIGHT  = 6'd11,
        S_G_CALC           = 6'd12,
        S_DIV_INIT         = 6'd13,
        S_DIV_RUN          = 6'd14,
        S_SET_V            = 6'd15,
        S_PROJ_START       = 6'd16,
        S_PROJ_WAIT        = 6'd17,
        S_COMMIT_READ      = 6'd18,
        S_COMMIT_WRITE     = 6'd19,
        S_F_READ_CUR       = 6'd20,
        S_F_READ_PREV      = 6'd21,
        S_F_CAPTURE_PREV   = 6'd22,
        S_F_DIV            = 6'd23,
        S_F_WEIGHT         = 6'd24,
        S_F_WRITE          = 6'd25,
        S_DONE             = 6'd26;

    reg [5:0] state;
    reg [11:0] index;
    reg [5:0] iteration;
    localparam [5:0] LAST_ITERATION = INNER_STEPS - 1;

    wire first_row = (index[11:6] == 6'd0);
    wire first_col = (index[5:0]  == 6'd0);
    wire last_row  = (index[11:6] == 6'd63);
    wire last_col  = (index[5:0]  == 6'd63);

    wire [11:0] prev_x_addr = first_row ? index : (index - 12'd64);
    wire [11:0] prev_y_addr = first_col ? index : (index - 12'd1);
    wire [11:0] below_addr  = last_row  ? index : (index + 12'd64);
    wire [11:0] right_addr  = last_col  ? index : (index + 12'd1);

    // BRAM control signals.
    reg f_en, f_we;
    reg [11:0] f_addr;
    reg [15:0] f_din;
    wire [15:0] f_dout;

    reg u_en, u_we;
    reg [11:0] u_addr;
    reg [15:0] u_din;
    wire [15:0] u_dout;

    reg px_en, px_we;
    reg [11:0] px_addr;
    reg [15:0] px_din;
    wire [15:0] px_dout;

    reg py_en, py_we;
    reg [11:0] py_addr;
    reg [15:0] py_din;
    wire [15:0] py_dout;

    reg pnx_en, pnx_we;
    reg [11:0] pnx_addr;
    reg [15:0] pnx_din;
    wire [15:0] pnx_dout;

    reg pny_en, pny_we;
    reg [11:0] pny_addr;
    reg [15:0] pny_din;
    wire [15:0] pny_dout;

    reg out_we;
    reg [11:0] out_addr;
    reg [15:0] out_din;
    sp_bram_4096x16 u_f_mem (
        .clk(clk), .en(f_en), .we(f_we), .addr(f_addr), .din(f_din), .dout(f_dout)
    );
    sp_bram_4096x16 u_work_mem (
        .clk(clk), .en(u_en), .we(u_we), .addr(u_addr), .din(u_din), .dout(u_dout)
    );
    sp_bram_4096x16 u_px_mem (
        .clk(clk), .en(px_en), .we(px_we), .addr(px_addr), .din(px_din), .dout(px_dout)
    );
    sp_bram_4096x16 u_py_mem (
        .clk(clk), .en(py_en), .we(py_we), .addr(py_addr), .din(py_din), .dout(py_dout)
    );
    sp_bram_4096x16 u_pnx_mem (
        .clk(clk), .en(pnx_en), .we(pnx_we), .addr(pnx_addr), .din(pnx_din), .dout(pnx_dout)
    );
    sp_bram_4096x16 u_pny_mem (
        .clk(clk), .en(pny_en), .we(pny_we), .addr(pny_addr), .din(pny_din), .dout(pny_dout)
    );

    // Output memory: one internal write port and one synchronous host read port.
    wire [15:0] out_dout;
    assign read_data = out_dout;
    sdp_bram_4096x16 u_out_mem (
        .clk(clk),
        .we_a(out_we), .addr_a(out_addr), .din_a(out_din),
        .en_b(read_en), .addr_b(read_addr), .dout_b(out_dout)
    );
    always @(posedge clk) begin
        if (!rst_n)
            read_valid <= 1'b0;
        else
            read_valid <= read_en;
    end

    assign ready = (state == S_IDLE);
    assign busy  = (state != S_IDLE);

    // Input and pipeline registers.
    reg signed [15:0] f_hold;
    reg signed [15:0] px_cur_hold, py_cur_hold;
    reg signed [15:0] px_prev_hold, py_prev_hold;
    reg signed [17:0] div_hold;
    reg signed [31:0] weighted_hold;

    wire signed [31:0] updated_wide =
        $signed(f_hold) + ($signed(weighted_hold) >>> 11);

    wire signed [17:0] px_cur_ext  = {{2{px_cur_hold[15]}},  px_cur_hold};
    wire signed [17:0] py_cur_ext  = {{2{py_cur_hold[15]}},  py_cur_hold};
    wire signed [17:0] px_prev_ext = {{2{px_prev_hold[15]}}, px_prev_hold};
    wire signed [17:0] py_prev_ext = {{2{py_prev_hold[15]}}, py_prev_hold};

    // Gradient and radix-16 restoring divide by five: exact truncation of |g|*64/5.
    reg signed [15:0] u_here, u_below, u_right;
    reg signed [15:0] px_grad_hold, py_grad_hold;
    wire signed [17:0] u_here_ext  = {{2{u_here[15]}},  u_here};
    wire signed [17:0] u_below_ext = {{2{u_below[15]}}, u_below};
    wire signed [17:0] u_right_ext = {{2{u_right[15]}}, u_right};

    reg signed [17:0] grad_x_q, grad_y_q;
    reg gx_neg, gy_neg;
    wire [17:0] abs_grad_x = grad_x_q[17] ? (~grad_x_q + 18'd1) : grad_x_q;
    wire [17:0] abs_grad_y = grad_y_q[17] ? (~grad_y_q + 18'd1) : grad_y_q;

    reg [23:0] dividend_x, dividend_y;
    reg [23:0] quotient_x, quotient_y;
    reg [3:0] rem_x, rem_y;
    reg [4:0] div_count;

    // Radix-16 restoring divide by 5: consume 4 dividend bits per clock.
    // All 4 substeps are combinational and bit-exact to four original clocks.
    // For unsigned long division by constant 5, remainder is always 0..4.
    wire [3:0] trial_x0 = {rem_x[2:0], dividend_x[23]};
    wire take_x0 = (trial_x0 >= 4'd5);
    wire [3:0] rem_x1 = take_x0 ? (trial_x0 - 4'd5) : trial_x0;
    wire [3:0] trial_x1 = {rem_x1[2:0], dividend_x[22]};
    wire take_x1 = (trial_x1 >= 4'd5);
    wire [3:0] rem_x2 = take_x1 ? (trial_x1 - 4'd5) : trial_x1;
    wire [3:0] trial_x2 = {rem_x2[2:0], dividend_x[21]};
    wire take_x2 = (trial_x2 >= 4'd5);
    wire [3:0] rem_x3 = take_x2 ? (trial_x2 - 4'd5) : trial_x2;
    wire [3:0] trial_x3 = {rem_x3[2:0], dividend_x[20]};
    wire take_x3 = (trial_x3 >= 4'd5);
    wire [3:0] rem_x4 = take_x3 ? (trial_x3 - 4'd5) : trial_x3;
    wire [3:0] next_rem_x = rem_x4;
    wire [23:0] next_quo_x = {quotient_x[19:0], take_x0, take_x1, take_x2, take_x3};

    // Radix-16 restoring divide by 5: consume 4 dividend bits per clock.
    // All 4 substeps are combinational and bit-exact to four original clocks.
    // For unsigned long division by constant 5, remainder is always 0..4.
    wire [3:0] trial_y0 = {rem_y[2:0], dividend_y[23]};
    wire take_y0 = (trial_y0 >= 4'd5);
    wire [3:0] rem_y1 = take_y0 ? (trial_y0 - 4'd5) : trial_y0;
    wire [3:0] trial_y1 = {rem_y1[2:0], dividend_y[22]};
    wire take_y1 = (trial_y1 >= 4'd5);
    wire [3:0] rem_y2 = take_y1 ? (trial_y1 - 4'd5) : trial_y1;
    wire [3:0] trial_y2 = {rem_y2[2:0], dividend_y[21]};
    wire take_y2 = (trial_y2 >= 4'd5);
    wire [3:0] rem_y3 = take_y2 ? (trial_y2 - 4'd5) : trial_y2;
    wire [3:0] trial_y3 = {rem_y3[2:0], dividend_y[20]};
    wire take_y3 = (trial_y3 >= 4'd5);
    wire [3:0] rem_y4 = take_y3 ? (trial_y3 - 4'd5) : trial_y3;
    wire [3:0] next_rem_y = rem_y4;
    wire [23:0] next_quo_y = {quotient_y[19:0], take_y0, take_y1, take_y2, take_y3};

    wire signed [31:0] delta_x =
        gx_neg ? -$signed({8'd0, quotient_x}) : $signed({8'd0, quotient_x});
    wire signed [31:0] delta_y =
        gy_neg ? -$signed({8'd0, quotient_y}) : $signed({8'd0, quotient_y});

    reg signed [15:0] vx_q, vy_q;
    wire proj_start = (state == S_PROJ_START);
    wire proj_ready, proj_valid;
    wire signed [15:0] proj_x, proj_y;

    tv_dual_project_q11 u_projection (
        .clk(clk), .rst_n(rst_n), .start(proj_start),
        .vx_in(vx_q), .vy_in(vy_q),
        .ready(proj_ready), .valid_out(proj_valid),
        .px_out(proj_x), .py_out(proj_y)
    );

    // All RAM ports are explicitly scheduled by the FSM.
    always @* begin
        f_en = 1'b0; f_we = 1'b0; f_addr = load_addr; f_din = load_data;
        u_en = 1'b0; u_we = 1'b0; u_addr = index; u_din = updated_wide[15:0];
        px_en = 1'b0; px_we = 1'b0; px_addr = index; px_din = 16'd0;
        py_en = 1'b0; py_we = 1'b0; py_addr = index; py_din = 16'd0;
        pnx_en = 1'b0; pnx_we = 1'b0; pnx_addr = index; pnx_din = 16'd0;
        pny_en = 1'b0; pny_we = 1'b0; pny_addr = index; pny_din = 16'd0;
        out_we = 1'b0; out_addr = index; out_din = updated_wide[15:0];

        case (state)
            S_IDLE: begin
                if (load_we) begin
                    f_en = 1'b1; f_we = 1'b1;
                    f_addr = load_addr; f_din = load_data;
                end
            end

            S_INIT: begin
                px_en = 1'b1; px_we = 1'b1; px_addr = index; px_din = 16'd0;
                py_en = 1'b1; py_we = 1'b1; py_addr = index; py_din = 16'd0;
                pnx_en = 1'b1; pnx_we = 1'b1; pnx_addr = index; pnx_din = 16'd0;
                pny_en = 1'b1; pny_we = 1'b1; pny_addr = index; pny_din = 16'd0;
            end

            S_U_READ_CUR: begin
                f_en = 1'b1; f_addr = index;
                px_en = 1'b1; px_addr = index;
                py_en = 1'b1; py_addr = index;
            end
            S_U_READ_PREV: begin
                px_en = 1'b1; px_addr = prev_x_addr;
                py_en = 1'b1; py_addr = prev_y_addr;
            end
            S_U_WRITE: begin
                u_en = 1'b1; u_we = 1'b1; u_addr = index;
                u_din = updated_wide[15:0];
            end

            S_G_READ_HERE: begin
                u_en = 1'b1; u_addr = index;
                px_en = 1'b1; px_addr = index;
                py_en = 1'b1; py_addr = index;
            end
            S_G_READ_BELOW: begin
                u_en = 1'b1; u_addr = below_addr;
            end
            S_G_READ_RIGHT: begin
                u_en = 1'b1; u_addr = right_addr;
            end

            S_PROJ_WAIT: begin
                if (proj_valid) begin
                    pnx_en = 1'b1; pnx_we = 1'b1; pnx_addr = index; pnx_din = proj_x;
                    pny_en = 1'b1; pny_we = 1'b1; pny_addr = index; pny_din = proj_y;
                end
            end
            S_COMMIT_READ: begin
                pnx_en = 1'b1; pnx_addr = index;
                pny_en = 1'b1; pny_addr = index;
            end
            S_COMMIT_WRITE: begin
                px_en = 1'b1; px_we = 1'b1; px_addr = index; px_din = pnx_dout;
                py_en = 1'b1; py_we = 1'b1; py_addr = index; py_din = pny_dout;
            end

            S_F_READ_CUR: begin
                f_en = 1'b1; f_addr = index;
                px_en = 1'b1; px_addr = index;
                py_en = 1'b1; py_addr = index;
            end
            S_F_READ_PREV: begin
                px_en = 1'b1; px_addr = prev_x_addr;
                py_en = 1'b1; py_addr = prev_y_addr;
            end
            S_F_WRITE: begin
                out_we = 1'b1; out_addr = index; out_din = updated_wide[15:0];
            end
            default: begin end
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            index <= 12'd0;
            iteration <= 6'd0;
            done <= 1'b0;

            f_hold <= 16'sd0;
            px_cur_hold <= 16'sd0; py_cur_hold <= 16'sd0;
            px_prev_hold <= 16'sd0; py_prev_hold <= 16'sd0;
            div_hold <= 18'sd0;
            weighted_hold <= 32'sd0;

            u_here <= 16'sd0; u_below <= 16'sd0; u_right <= 16'sd0;
            px_grad_hold <= 16'sd0; py_grad_hold <= 16'sd0;
            grad_x_q <= 18'sd0; grad_y_q <= 18'sd0;
            gx_neg <= 1'b0; gy_neg <= 1'b0;
            dividend_x <= 24'd0; dividend_y <= 24'd0;
            quotient_x <= 24'd0; quotient_y <= 24'd0;
            rem_x <= 4'd0; rem_y <= 4'd0; div_count <= 5'd0;
            vx_q <= 16'sd0; vy_q <= 16'sd0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start && !load_we) begin
                        index <= 12'd0;
                        iteration <= 6'd0;
                        state <= S_INIT;
                    end
                end

                S_INIT: begin
                    if (index == 12'd4095) begin
                        index <= 12'd0;
                        state <= S_U_READ_CUR;
                    end else index <= index + 1'b1;
                end

                S_U_READ_CUR: state <= S_U_READ_PREV;
                S_U_READ_PREV: begin
                    f_hold <= $signed(f_dout);
                    px_cur_hold <= $signed(px_dout);
                    py_cur_hold <= $signed(py_dout);
                    state <= S_U_CAPTURE_PREV;
                end
                S_U_CAPTURE_PREV: begin
                    px_prev_hold <= first_row ? 16'sd0 : $signed(px_dout);
                    py_prev_hold <= first_col ? 16'sd0 : $signed(py_dout);
                    state <= S_U_DIV;
                end
                S_U_DIV: begin
                    div_hold <= px_cur_ext + py_cur_ext - px_prev_ext - py_prev_ext;
                    state <= S_U_WEIGHT;
                end
                S_U_WEIGHT: begin
                    weighted_hold <= $signed(div_hold) * 32'sd20;
                    state <= S_U_WRITE;
                end
                S_U_WRITE: begin
                    if (index == 12'd4095) begin
                        index <= 12'd0;
                        state <= S_G_READ_HERE;
                    end else begin
                        index <= index + 1'b1;
                        state <= S_U_READ_CUR;
                    end
                end

                S_G_READ_HERE: state <= S_G_READ_BELOW;
                S_G_READ_BELOW: begin
                    u_here <= $signed(u_dout);
                    px_grad_hold <= $signed(px_dout);
                    py_grad_hold <= $signed(py_dout);
                    state <= S_G_READ_RIGHT;
                end
                S_G_READ_RIGHT: begin
                    u_below <= $signed(u_dout);
                    state <= S_G_CAPTURE_RIGHT;
                end
                S_G_CAPTURE_RIGHT: begin
                    u_right <= $signed(u_dout);
                    state <= S_G_CALC;
                end
                S_G_CALC: begin
                    grad_x_q <= last_row ? 18'sd0 : (u_below_ext - u_here_ext);
                    grad_y_q <= last_col ? 18'sd0 : (u_right_ext - u_here_ext);
                    state <= S_DIV_INIT;
                end
                S_DIV_INIT: begin
                    gx_neg <= grad_x_q[17];
                    gy_neg <= grad_y_q[17];
                    dividend_x <= {abs_grad_x, 6'b0};
                    dividend_y <= {abs_grad_y, 6'b0};
                    quotient_x <= 24'd0; quotient_y <= 24'd0;
                    rem_x <= 4'd0; rem_y <= 4'd0; div_count <= 5'd0;
                    state <= S_DIV_RUN;
                end
                S_DIV_RUN: begin
                    dividend_x <= {dividend_x[19:0], 4'b0};
                    dividend_y <= {dividend_y[19:0], 4'b0};
                    quotient_x <= next_quo_x;
                    quotient_y <= next_quo_y;
                    rem_x <= next_rem_x;
                    rem_y <= next_rem_y;
                    if (div_count == 5'd5)
                        state <= S_SET_V;
                    else
                        div_count <= div_count + 1'b1;
                end
                S_SET_V: begin
                    vx_q <= last_row ? 16'sd0 : (px_grad_hold + delta_x);
                    vy_q <= last_col ? 16'sd0 : (py_grad_hold + delta_y);
                    state <= S_PROJ_START;
                end
                S_PROJ_START: begin
                    if (proj_ready)
                        state <= S_PROJ_WAIT;
                end
                S_PROJ_WAIT: begin
                    if (proj_valid) begin
                        if (index == 12'd4095) begin
                            index <= 12'd0;
                            state <= S_COMMIT_READ;
                        end else begin
                            index <= index + 1'b1;
                            state <= S_G_READ_HERE;
                        end
                    end
                end
                S_COMMIT_READ: state <= S_COMMIT_WRITE;
                S_COMMIT_WRITE: begin
                    if (index == 12'd4095) begin
                        index <= 12'd0;
                        if (iteration == LAST_ITERATION) begin
                            state <= S_F_READ_CUR;
                        end else begin
                            iteration <= iteration + 1'b1;
                            state <= S_U_READ_CUR;
                        end
                    end else begin
                        index <= index + 1'b1;
                        state <= S_COMMIT_READ;
                    end
                end

                S_F_READ_CUR: state <= S_F_READ_PREV;
                S_F_READ_PREV: begin
                    f_hold <= $signed(f_dout);
                    px_cur_hold <= $signed(px_dout);
                    py_cur_hold <= $signed(py_dout);
                    state <= S_F_CAPTURE_PREV;
                end
                S_F_CAPTURE_PREV: begin
                    px_prev_hold <= first_row ? 16'sd0 : $signed(px_dout);
                    py_prev_hold <= first_col ? 16'sd0 : $signed(py_dout);
                    state <= S_F_DIV;
                end
                S_F_DIV: begin
                    div_hold <= px_cur_ext + py_cur_ext - px_prev_ext - py_prev_ext;
                    state <= S_F_WEIGHT;
                end
                S_F_WEIGHT: begin
                    weighted_hold <= $signed(div_hold) * 32'sd20;
                    state <= S_F_WRITE;
                end
                S_F_WRITE: begin
                    if (index == 12'd4095) begin
                        index <= 12'd0;
                        state <= S_DONE;
                    end else begin
                        index <= index + 1'b1;
                        state <= S_F_READ_CUR;
                    end
                end
                S_DONE: begin
                    done <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
