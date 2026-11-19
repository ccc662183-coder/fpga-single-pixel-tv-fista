`timescale 1ns / 1ps

// UART protocol core: distributed RAM used for echo_payload.
// Original stop-and-wait state machine and interfaces retained.
module uart_protocol_core #(
    parameter integer CLK_HZ = 200_000_000,
    parameter integer FIFO_ADDR_W = 12,
    parameter [26:0] DEFAULT_BAUD = 27'd1000000,
    parameter integer GUARD_CYCLES = 400000,
    parameter integer DRAIN_TIMEOUT_CYCLES = 20000000,
    parameter integer PREP_TIMEOUT_CYCLES = 400000000,
    parameter integer CONFIRM_TIMEOUT_CYCLES = 400000000,
    parameter integer RESP_TIMEOUT_CYCLES = 400000000
)(
    input wire clk,
    input wire rst_n,
    input wire uart_rx_i,
    output wire uart_tx_o,
    output wire [26:0] active_baud,
    output wire switch_pending,
    output wire baud_changed,
    output wire rollback_pulse,
    output wire [FIFO_ADDR_W:0] rx_fifo_level,
    output reg [31:0] rx_fifo_drop_count,
    output wire [31:0] crc_error_count,
    output wire [31:0] format_error_count,
    output wire [31:0] timeout_count
);
    wire link_flush;
    wire link_rst_n = rst_n && !link_flush;

    wire [7:0] rx_byte;
    wire rx_valid, rx_busy;
    wire rx_frame_error, rx_false_start;
    uart_rx #(.CLK_HZ(CLK_HZ), .MIN_CLKS_PER_BIT(16)) u_uart_rx (
        .clk(clk), .rst_n(link_rst_n), .rx_i(uart_rx_i),
        .baud_rate(active_baud), .rx_data(rx_byte),
        .rx_valid(rx_valid), .rx_frame_error(rx_frame_error),
        .rx_false_start(rx_false_start), .rx_busy(rx_busy)
    );

    wire [7:0] queued_byte;
    wire queued_valid, queued_ready;
    wire fifo_in_ready, rx_fifo_full, rx_fifo_empty;
    wire pkt_rx_valid;
    wire parser_byte_valid = queued_valid && !pkt_rx_valid;
    assign queued_ready = parser_byte_valid;

    uart_fifo #(.ADDR_W(FIFO_ADDR_W)) u_rx_fifo (
        .clk(clk), .rst_n(link_rst_n),
        .in_data(rx_byte), .in_valid(rx_valid), .in_ready(fifo_in_ready),
        .out_data(queued_byte), .out_valid(queued_valid),
        .out_ready(queued_ready), .level(rx_fifo_level),
        .full(rx_fifo_full), .empty(rx_fifo_empty)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rx_fifo_drop_count <= 32'd0;
        else if (rx_valid && !fifo_in_ready)
            rx_fifo_drop_count <= rx_fifo_drop_count + 1'b1;
    end

    wire [7:0] pkt_rx_type;
    wire [15:0] pkt_rx_seq;
    wire [8:0] pkt_rx_len;
    wire [7:0] pkt_rx_payload_data;
    wire [31:0] pkt_rx_busy_drop;
    wire pkt_rx_ready;
    reg [7:0] pkt_rx_payload_addr;
    uart_packet_rx #(.CLK_HZ(CLK_HZ)) u_packet_rx (
        .clk(clk), .rst_n(link_rst_n),
        .byte_data(queued_byte), .byte_valid(parser_byte_valid),
        .packet_valid(pkt_rx_valid), .packet_ready(pkt_rx_ready),
        .packet_type(pkt_rx_type), .packet_seq(pkt_rx_seq),
        .packet_len(pkt_rx_len), .payload_addr(pkt_rx_payload_addr),
        .payload_data(pkt_rx_payload_data),
        .crc_error_count(crc_error_count),
        .format_error_count(format_error_count),
        .timeout_count(timeout_count), .busy_drop_count(pkt_rx_busy_drop)
    );

    localparam [2:0]
        R_IDLE       = 3'd0,
        R_COPY       = 3'd1,
        R_RELEASE    = 3'd2,
        R_CMD        = 3'd3,
        R_DATA_START = 3'd4,
        R_DATA_DONE  = 3'd5;

    reg [2:0] r_state;
    reg [7:0] req_type;
    reg [15:0] req_seq;
    reg [8:0] req_len;
    reg [8:0] copy_index;
    reg [31:0] req_baud;

    // Infer LUTRAM instead of 2048 FDRE/large fabric muxes.
    // Read is asynchronous; memory is intentionally not reset.
    (* ram_style = "distributed" *) reg [7:0] echo_payload [0:255];

    wire echo_write = rst_n && !link_flush &&
                      (r_state == R_COPY) && (copy_index < req_len);
    always @(posedge clk) begin
        if (echo_write)
            echo_payload[copy_index[7:0]] <= pkt_rx_payload_data;
    end

    always @(*)
        pkt_rx_payload_addr = copy_index[7:0];
    assign pkt_rx_ready = (r_state == R_RELEASE);

    wire ctrl_cmd_ready, ctrl_resp_valid, ctrl_resp_ready;
    wire [7:0] ctrl_resp_type;
    wire [15:0] ctrl_resp_seq;
    wire [8:0] ctrl_resp_len;
    wire [31:0] ctrl_resp_value;
    wire ctrl_resp_done;
    wire tx_busy, tx_ready, tx_done;
    wire pkt_tx_busy, pkt_tx_done;

    wire link_idle = rx_fifo_empty && !rx_busy && !pkt_rx_valid &&
                     (r_state == R_IDLE) && !pkt_tx_busy && !tx_busy;

    uart_baud_switch_ctrl #(
        .DEFAULT_BAUD(DEFAULT_BAUD),
        .GUARD_CYCLES(GUARD_CYCLES),
        .DRAIN_TIMEOUT_CYCLES(DRAIN_TIMEOUT_CYCLES),
        .PREP_TIMEOUT_CYCLES(PREP_TIMEOUT_CYCLES),
        .CONFIRM_TIMEOUT_CYCLES(CONFIRM_TIMEOUT_CYCLES),
        .RESP_TIMEOUT_CYCLES(RESP_TIMEOUT_CYCLES)
    ) u_baud_ctrl (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(r_state == R_CMD), .cmd_ready(ctrl_cmd_ready),
        .cmd_type(req_type), .cmd_seq(req_seq),
        .cmd_len(req_len), .cmd_baud(req_baud),
        .resp_valid(ctrl_resp_valid), .resp_ready(ctrl_resp_ready),
        .resp_type(ctrl_resp_type), .resp_seq(ctrl_resp_seq),
        .resp_len(ctrl_resp_len), .resp_value(ctrl_resp_value),
        .resp_done(ctrl_resp_done), .link_idle(link_idle),
        .active_baud(active_baud), .baud_changed(baud_changed),
        .rollback_pulse(rollback_pulse), .link_flush(link_flush),
        .switch_pending(switch_pending),
        .timeout_count(), .rejected_count()
    );

    wire ctrl_start = ctrl_resp_valid && !pkt_tx_busy;
    wire data_start = (r_state == R_DATA_START) &&
                      !pkt_tx_busy && !ctrl_resp_valid && !switch_pending;
    wire pkt_tx_start = ctrl_start || data_start;
    assign ctrl_resp_ready = ctrl_start;

    wire [7:0] pkt_tx_type = ctrl_start ? ctrl_resp_type : 8'h21;
    wire [15:0] pkt_tx_seq = ctrl_start ? ctrl_resp_seq : req_seq;
    wire [8:0] pkt_tx_len = ctrl_start ? ctrl_resp_len : req_len;
    wire [7:0] pkt_tx_payload_addr;
    wire [7:0] pkt_tx_payload_data;
    wire [7:0] tx_byte;
    wire tx_valid;
    reg sending_ctrl;

    wire [7:0] ctrl_payload_byte =
        (pkt_tx_payload_addr == 8'd0) ? ctrl_resp_value[7:0] :
        (pkt_tx_payload_addr == 8'd1) ? ctrl_resp_value[15:8] :
        (pkt_tx_payload_addr == 8'd2) ? ctrl_resp_value[23:16] :
        (pkt_tx_payload_addr == 8'd3) ? ctrl_resp_value[31:24] : 8'd0;

    assign pkt_tx_payload_data = sending_ctrl ? ctrl_payload_byte :
                                 echo_payload[pkt_tx_payload_addr];
    assign ctrl_resp_done = pkt_tx_done && sending_ctrl;

    uart_packet_tx u_packet_tx (
        .clk(clk), .rst_n(link_rst_n),
        .packet_start(pkt_tx_start), .packet_type(pkt_tx_type),
        .packet_seq(pkt_tx_seq), .packet_len(pkt_tx_len),
        .payload_addr(pkt_tx_payload_addr),
        .payload_data(pkt_tx_payload_data),
        .tx_data(tx_byte), .tx_valid(tx_valid),
        .tx_ready(tx_ready), .tx_done(tx_done),
        .packet_busy(pkt_tx_busy), .packet_done(pkt_tx_done),
        .invalid_len()
    );

    uart_tx #(.CLK_HZ(CLK_HZ)) u_uart_tx (
        .clk(clk), .rst_n(link_rst_n),
        .baud_rate(active_baud),
        .tx_data(tx_byte), .tx_valid(tx_valid),
        .tx_ready(tx_ready), .tx_o(uart_tx_o),
        .tx_busy(tx_busy), .tx_done(tx_done)
    );

    // Deliberately preserve the original dispatch FSM.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_state <= R_IDLE;
            req_type <= 8'd0;
            req_seq <= 16'd0;
            req_len <= 9'd0;
            req_baud <= 32'd0;
            copy_index <= 9'd0;
            sending_ctrl <= 1'b0;
        end else if (link_flush) begin
            r_state <= R_IDLE;
            copy_index <= 9'd0;
            req_baud <= 32'd0;
            sending_ctrl <= 1'b0;
        end else begin
            if (ctrl_start)
                sending_ctrl <= 1'b1;
            else if (data_start)
                sending_ctrl <= 1'b0;

            case (r_state)
                R_IDLE: if (pkt_rx_valid) begin
                    req_type <= pkt_rx_type;
                    req_seq <= pkt_rx_seq;
                    req_len <= pkt_rx_len;
                    req_baud <= 32'd0;
                    copy_index <= 9'd0;
                    r_state <= R_COPY;
                end
                R_COPY: begin
                    if (copy_index < req_len) begin
                        // Echo buffer write now happens in separate clock-only block.
                        case (copy_index)
                            9'd0: req_baud[7:0] <= pkt_rx_payload_data;
                            9'd1: req_baud[15:8] <= pkt_rx_payload_data;
                            9'd2: req_baud[23:16] <= pkt_rx_payload_data;
                            9'd3: req_baud[31:24] <= pkt_rx_payload_data;
                            default: ;
                        endcase
                        copy_index <= copy_index + 1'b1;
                    end else
                        r_state <= R_RELEASE;
                end
                R_RELEASE: begin
                    if (req_type == 8'h20)
                        r_state <= R_DATA_START;
                    else
                        r_state <= R_CMD;
                end
                R_CMD: if (ctrl_cmd_ready)
                    r_state <= R_IDLE;
                R_DATA_START: if (data_start)
                    r_state <= R_DATA_DONE;
                R_DATA_DONE: if (pkt_tx_done && !sending_ctrl)
                    r_state <= R_IDLE;
                default: r_state <= R_IDLE;
            endcase
        end
    end
endmodule
