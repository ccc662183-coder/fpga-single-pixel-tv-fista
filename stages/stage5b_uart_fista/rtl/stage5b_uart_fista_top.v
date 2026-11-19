`timescale 1ns / 1ps
// Stage-5B: PL-only TV-FISTA + fixed 1Mbps UART on AX7020, single 50MHz clock.
// Deliberately keeps all Stage-4C numerical RTL unchanged.
// Packet: A5 5A 01 TYPE SEQ_LE16 LEN_LE16 DATA CRC16_CCITT_FALSE_LE16.
// 40 RESET -> 49 ACK; 40 LOAD -> 41 ACK; see README for full command map.
module stage5b_uart_fista_top #(
    parameter integer OUTER_ITERS = 40,
    parameter integer TV_INNER_STEPS = 35
)(
    input wire clk_50m,
    input wire rst_n,
    input wire uart_rx_i,
    output wire uart_tx_o
);
    reg [2:0] reset_sync = 3'b000;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) reset_sync <= 3'b000;
        else        reset_sync <= {reset_sync[1:0], 1'b1};
    end
    wire link_rst_n = reset_sync[2];
    // The algorithm core can be reset independently without tearing down UART.
    reg [3:0] core_reset_count;
    wire core_rst_n = link_rst_n && (core_reset_count == 4'd0);

    // Reuse proven Stage-5A PHY and framed packet modules.
    wire [7:0] rx_byte;
    wire rx_valid, rx_busy, rx_frame_error, rx_false_start;
    uart_rx #(.CLK_HZ(50_000_000),.MIN_CLKS_PER_BIT(16)) u_rx (
       .clk(clk_50m),.rst_n(link_rst_n),.rx_i(uart_rx_i),
       .baud_rate(27'd1000000),.rx_data(rx_byte),.rx_valid(rx_valid),
       .rx_frame_error(rx_frame_error),.rx_false_start(rx_false_start),.rx_busy(rx_busy)
    );

    wire [7:0] fifo_byte;
    wire fifo_valid, fifo_ready, fifo_in_ready;
    wire [12:0] fifo_level;
    wire fifo_full, fifo_empty;
    uart_fifo #(.ADDR_W(12)) u_fifo (
      .clk(clk_50m),.rst_n(link_rst_n),
      .in_data(rx_byte),.in_valid(rx_valid),.in_ready(fifo_in_ready),
      .out_data(fifo_byte),.out_valid(fifo_valid),.out_ready(fifo_ready),
      .level(fifo_level),.full(fifo_full),.empty(fifo_empty)
    );

    wire pkt_valid;
    wire pkt_ready;
    wire [7:0] pkt_type;
    wire [15:0] pkt_seq;
    wire [8:0] pkt_len;
    wire [7:0] pkt_payload_data;
    wire [31:0] crc_error_count, format_error_count, timeout_count, busy_drop_count;
    reg [7:0] pkt_payload_addr;
    assign fifo_ready = fifo_valid && !pkt_valid;
    uart_packet_rx #(.CLK_HZ(50_000_000),.TIMEOUT_CYCLES(5_000_000)) u_pkt_rx (
       .clk(clk_50m),.rst_n(link_rst_n),
       .byte_data(fifo_byte),.byte_valid(fifo_valid && !pkt_valid),
       .packet_valid(pkt_valid),.packet_ready(pkt_ready),
       .packet_type(pkt_type),.packet_seq(pkt_seq),.packet_len(pkt_len),
       .payload_addr(pkt_payload_addr),.payload_data(pkt_payload_data),
       .crc_error_count(crc_error_count),.format_error_count(format_error_count),
       .timeout_count(timeout_count),.busy_drop_count(busy_drop_count)
    );

    wire [7:0] tx_byte;
    wire tx_valid, tx_ready, tx_done, tx_busy;
    wire packet_tx_busy, packet_tx_done;
    wire [7:0] packet_tx_addr;
    wire [7:0] packet_tx_data;
    reg [7:0] response_type;
    reg [15:0] response_seq;
    reg [8:0] response_len;
    wire packet_tx_start;
    uart_packet_tx u_pkt_tx (
      .clk(clk_50m),.rst_n(link_rst_n),
      .packet_start(packet_tx_start),.packet_type(response_type),
      .packet_seq(response_seq),.packet_len(response_len),
      .payload_addr(packet_tx_addr),.payload_data(packet_tx_data),
      .tx_data(tx_byte),.tx_valid(tx_valid),.tx_ready(tx_ready),.tx_done(tx_done),
      .packet_busy(packet_tx_busy),.packet_done(packet_tx_done),.invalid_len()
    );
    uart_tx #(.CLK_HZ(50_000_000)) u_tx (
      .clk(clk_50m),.rst_n(link_rst_n),.baud_rate(27'd1000000),
      .tx_data(tx_byte),.tx_valid(tx_valid),.tx_ready(tx_ready),
      .tx_o(uart_tx_o),.tx_busy(tx_busy),.tx_done(tx_done)
    );

    wire core_meas_ready, core_ready, core_busy, core_done;
    wire core_range_error, core_protocol_error;
    wire [5:0] core_iter;
    wire core_read_valid;
    wire signed [15:0] core_read_data;
    reg [10:0] loaded_count;
    reg [4:0] next_chunk;
    reg completed;
    reg [31:0] compute_cycles;
    reg [7:0] last_error;

    reg [3:0] fsm;
    localparam [3:0]
        S_IDLE = 0, S_LOAD = 1, S_ECHO = 2,
        S_READ_REQ = 3, S_READ_CAPTURE = 4,
        S_RELEASE = 5, S_TX_START = 6, S_TX_WAIT = 7;
    reg [5:0] load_word_index;
    reg [5:0] load_words_target;
    reg [1:0] load_byte_index;
    reg [23:0] load_partial;
    reg [8:0] echo_byte_index;
    reg [4:0] read_chunk;
    reg [6:0] read_pixel_index;

    wire load_word_write = (fsm == S_LOAD) && (load_byte_index == 2'd3)
                          && core_meas_ready;
    wire core_start = (fsm == S_IDLE) && pkt_valid &&
                      pkt_type == 8'h42 && pkt_len == 9'd0 &&
                      next_chunk == 5'd17 && loaded_count == 11'd1024 &&
                      core_ready && !completed && core_reset_count == 4'd0;
    wire core_read_en = (fsm == S_READ_REQ);
    wire [11:0] core_read_addr = {read_chunk,7'b0} + {5'd0,read_pixel_index};
    tv_fista_top_q11 #(.OUTER_ITERS(OUTER_ITERS),.TV_INNER_STEPS(TV_INNER_STEPS))
      u_compute (
       .clk(clk_50m),.rst_n(core_rst_n),
       .meas_load_we(load_word_write),.meas_load_addr(loaded_count[9:0]),
       .meas_load_data({pkt_payload_data,load_partial}),
       .meas_load_ready(core_meas_ready),
       .start(core_start),.ready(core_ready),.busy(core_busy),.done(core_done),
       .range_error(core_range_error),.protocol_error(core_protocol_error),
       .outer_iter(core_iter),.result_read_en(core_read_en),
       .result_read_addr(core_read_addr),.result_read_valid(core_read_valid),
       .result_read_data(core_read_data)
    );

    // One write per cycle for each buffer -> LUTRAM inference is possible.
    (* ram_style = "distributed" *) reg [7:0] echo_buffer [0:255];
    (* ram_style = "distributed" *) reg [15:0] pixel_buffer [0:127];
    always @(posedge clk_50m) begin
        if (link_rst_n && fsm == S_ECHO && echo_byte_index < pkt_len)
            echo_buffer[echo_byte_index[7:0]] <= pkt_payload_data;
        if (link_rst_n && fsm == S_READ_CAPTURE && core_read_valid)
            pixel_buffer[read_pixel_index] <= core_read_data;
    end

    // Snapshot response metadata before transmitting. Do not expose moving status
    // or result data while packet_tx serializes a packet over milliseconds.
    reg [10:0] snap_loaded;
    reg [7:0] snap_flags;
    reg [5:0] snap_iter;
    reg [31:0] snap_cycles;
    reg [15:0] snap_crc_err;
    reg [7:0] snap_chunk;
    reg [7:0] error_request;
    reg [7:0] error_code;

    reg [7:0] response_byte;
    always @(*) begin
      response_byte = 8'd0;
      case (response_type)
        8'h11: begin // GET_STATUS 1000000 baud, little-endian
            case (packet_tx_addr)
              8'd0: response_byte = 8'h40;
              8'd1: response_byte = 8'h42;
              8'd2: response_byte = 8'h0F;
              8'd3: response_byte = 8'h00;
              default: response_byte = 8'd0;
            endcase
        end
        8'h21: response_byte = echo_buffer[packet_tx_addr];
        8'h41: begin // LOAD_ACK [chunk, countL, countH, 0]
          case (packet_tx_addr)
            8'd0: response_byte = snap_chunk;
            8'd1: response_byte = snap_loaded[7:0];
            8'd2: response_byte = {5'd0,snap_loaded[10:8]};
            default: response_byte = 8'd0;
          endcase
        end
        8'h43, 8'h49: response_byte = 8'd0; // START/RESET_ACK
        8'h45: begin // STATUS [flags,iter,loadedLE16,cyclesLE32,crcLE16,zeros2]
          case (packet_tx_addr)
            8'd0: response_byte = snap_flags;
            8'd1: response_byte = {2'd0,snap_iter};
            8'd2: response_byte = snap_loaded[7:0];
            8'd3: response_byte = {5'd0,snap_loaded[10:8]};
            8'd4: response_byte = snap_cycles[7:0];
            8'd5: response_byte = snap_cycles[15:8];
            8'd6: response_byte = snap_cycles[23:16];
            8'd7: response_byte = snap_cycles[31:24];
            8'd8: response_byte = snap_crc_err[7:0];
            8'd9: response_byte = snap_crc_err[15:8];
            default: response_byte = 8'd0;
          endcase
        end
        8'h47: response_byte = packet_tx_addr[0] ?
                pixel_buffer[packet_tx_addr[7:1]][15:8] :
                pixel_buffer[packet_tx_addr[7:1]][7:0];
        8'h7F: response_byte = (packet_tx_addr == 8'd0) ? error_request : error_code;
        default: response_byte = 8'd0;
      endcase
    end
    assign packet_tx_data = response_byte;
    assign packet_tx_start = (fsm == S_TX_START) && !packet_tx_busy;
    assign pkt_ready = (fsm == S_RELEASE);

    // Parser exposes an asynchronous payload read port.
    always @(*) begin
        pkt_payload_addr = 8'd0;
        if (fsm == S_LOAD)
            pkt_payload_addr = 8'd1 + {load_word_index,2'b00} + {6'd0,load_byte_index};
        else if (fsm == S_ECHO)
            pkt_payload_addr = echo_byte_index[7:0];
    end

    // This control FSM is idle during most of the 40-iteration PL compute.
    always @(posedge clk_50m or negedge link_rst_n) begin
      if (!link_rst_n) begin
        core_reset_count <= 4'd8;
        fsm <= S_IDLE;
        loaded_count <= 11'd0;
        next_chunk <= 5'd0;
        completed <= 1'b0;
        compute_cycles <= 32'd0;
        last_error <= 8'd0;
        response_type <= 8'd0;
        response_seq <= 16'd0;
        response_len <= 9'd0;
        load_word_index <= 6'd0;
        load_words_target <= 6'd0;
        load_byte_index <= 2'd0;
        load_partial <= 24'd0;
        echo_byte_index <= 9'd0;
        read_chunk <= 5'd0;
        read_pixel_index <= 7'd0;
        snap_flags <= 8'd0;
        snap_iter <= 6'd0;
        snap_loaded <= 11'd0;
        snap_cycles <= 32'd0;
        snap_crc_err <= 16'd0;
        snap_chunk <= 8'd0;
        error_request <= 8'd0;
        error_code <= 8'd0;
      end else begin
        if (core_reset_count != 0)
            core_reset_count <= core_reset_count - 1'b1;
        if (core_busy)
            compute_cycles <= compute_cycles + 1'b1;
        if (core_done)
            completed <= 1'b1;
        case (fsm)
          S_IDLE: if (pkt_valid) begin
            response_seq <= pkt_seq;
            case (pkt_type)
              8'h10: if (pkt_len == 0) begin
                response_type <= 8'h11; response_len <= 9'd4; fsm <= S_RELEASE;
              end else begin
                response_type <= 8'h7F; response_len <= 9'd2;
                error_request <= pkt_type; error_code <= 8'd1; fsm <= S_RELEASE;
              end
              8'h20: begin // backward-compatible DATA_ECHO
                response_type <= 8'h21; response_len <= pkt_len;
                echo_byte_index <= 9'd0;
                fsm <= (pkt_len == 0) ? S_RELEASE : S_ECHO;
              end
              8'h48: if (pkt_len == 0) begin // RESET the compute core only
                core_reset_count <= 4'd8;
                loaded_count <= 11'd0;
                next_chunk <= 5'd0;
                completed <= 1'b0;
                compute_cycles <= 32'd0;
                last_error <= 8'd0;
                response_type <= 8'h49; response_len <= 9'd1;
                fsm <= S_RELEASE;
              end else begin
                response_type <= 8'h7F; response_len <= 9'd2;
                error_request <= pkt_type; error_code <= 8'd1; fsm <= S_RELEASE;
              end
              8'h40: if (next_chunk < 5'd17 && !core_busy && !completed &&
                       core_reset_count == 4'd0 && core_meas_ready &&
                       pkt_len == ((next_chunk == 5'd16) ? 9'd65 : 9'd253) &&
                       pkt_payload_data == {3'd0,next_chunk}) begin
                load_word_index <= 6'd0;
                load_byte_index <= 2'd0;
                load_partial <= 24'd0;
                load_words_target <= (next_chunk == 5'd16) ? 6'd16 : 6'd63;
                fsm <= S_LOAD;
              end else begin
                response_type <= 8'h7F; response_len <= 9'd2;
                error_request <= pkt_type; error_code <= 8'd2; fsm <= S_RELEASE;
              end
              8'h42: if (pkt_len == 0 && next_chunk == 5'd17 &&
                            loaded_count == 11'd1024 && core_ready &&
                            !completed && core_reset_count == 4'd0) begin
                response_type <= 8'h43; response_len <= 9'd1;
                compute_cycles <= 32'd0;
                completed <= 1'b0;
                fsm <= S_RELEASE;
              end else begin
                response_type <= 8'h7F; response_len <= 9'd2;
                error_request <= pkt_type; error_code <= 8'd3; fsm <= S_RELEASE;
              end
              8'h44: if (pkt_len == 0) begin
                response_type <= 8'h45; response_len <= 9'd12;
                snap_flags <= {3'd0,core_protocol_error,core_range_error,completed,core_busy,core_ready};
                snap_iter <= core_iter;
                snap_loaded <= loaded_count;
                snap_cycles <= compute_cycles;
                snap_crc_err <= crc_error_count[15:0];
                fsm <= S_RELEASE;
              end else begin
                response_type <= 8'h7F; response_len <= 9'd2;
                error_request <= pkt_type; error_code <= 8'd1; fsm <= S_RELEASE;
              end
              8'h46: if (pkt_len == 9'd1 && completed && !core_busy &&
                            pkt_payload_data < 8'd32) begin
                response_type <= 8'h47; response_len <= 9'd256;
                read_chunk <= pkt_payload_data[4:0];
                read_pixel_index <= 7'd0;
                fsm <= S_READ_REQ;
              end else begin
                response_type <= 8'h7F; response_len <= 9'd2;
                error_request <= pkt_type; error_code <= 8'd3; fsm <= S_RELEASE;
              end
              default: begin
                response_type <= 8'h7F; response_len <= 9'd2;
                error_request <= pkt_type; error_code <= 8'd1; fsm <= S_RELEASE;
              end
            endcase
          end
          S_LOAD: begin
            case (load_byte_index)
              2'd0: begin load_partial[7:0] <= pkt_payload_data; load_byte_index <= 2'd1; end
              2'd1: begin load_partial[15:8] <= pkt_payload_data; load_byte_index <= 2'd2; end
              2'd2: begin load_partial[23:16] <= pkt_payload_data; load_byte_index <= 2'd3; end
              2'd3: begin
                if (core_meas_ready) begin
                  loaded_count <= loaded_count + 1'b1;
                  load_byte_index <= 2'd0;
                  if (load_word_index + 1'b1 == load_words_target) begin
                    next_chunk <= next_chunk + 1'b1;
                    snap_loaded <= loaded_count + 1'b1;
                    snap_chunk <= {3'd0,next_chunk};
                    response_type <= 8'h41; response_len <= 9'd4;
                    fsm <= S_RELEASE;
                  end else load_word_index <= load_word_index + 1'b1;
                end else begin
                  response_type <= 8'h7F; response_len <= 9'd2;
                  error_request <= 8'h40; error_code <= 8'd4; fsm <= S_RELEASE;
                end
              end
            endcase
          end
          S_ECHO: begin
            if (echo_byte_index + 1'b1 >= pkt_len)
                fsm <= S_RELEASE;
            echo_byte_index <= echo_byte_index + 1'b1;
          end
          S_READ_REQ: fsm <= S_READ_CAPTURE;
          S_READ_CAPTURE: if (core_read_valid) begin
            if (read_pixel_index == 7'd127)
                fsm <= S_RELEASE;
            else begin
                read_pixel_index <= read_pixel_index + 1'b1;
                fsm <= S_READ_REQ;
            end
          end
          S_RELEASE: fsm <= S_TX_START;
          S_TX_START: if (!packet_tx_busy) fsm <= S_TX_WAIT;
          S_TX_WAIT: if (packet_tx_done) fsm <= S_IDLE;
          default: fsm <= S_IDLE;
        endcase
      end
    end
endmodule
