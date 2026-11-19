`timescale 1ns / 1ps

// UART packet receiver, 256-byte distributed-RAM payload buffer.
// Only memory write inference is changed versus original packet parser.
module uart_packet_rx #(
    parameter integer CLK_HZ = 200_000_000,
    parameter integer TIMEOUT_CYCLES = 20_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  byte_data,
    input  wire        byte_valid,
    output reg         packet_valid,
    input  wire        packet_ready,
    output reg [7:0]   packet_type,
    output reg [15:0]  packet_seq,
    output reg [8:0]   packet_len,
    input  wire [7:0]  payload_addr,
    output wire [7:0]  payload_data,
    output reg [31:0]  crc_error_count,
    output reg [31:0]  format_error_count,
    output reg [31:0]  timeout_count,
    output reg [31:0]  busy_drop_count
);

    localparam [3:0]
        S_SYNC1   = 4'd0,
        S_SYNC2   = 4'd1,
        S_VERSION = 4'd2,
        S_TYPE    = 4'd3,
        S_SEQ_LO  = 4'd4,
        S_SEQ_HI  = 4'd5,
        S_LEN_LO  = 4'd6,
        S_LEN_HI  = 4'd7,
        S_PAYLOAD = 4'd8,
        S_CRC_LO  = 4'd9,
        S_CRC_HI  = 4'd10,
        S_HOLD    = 4'd11;

    reg [3:0] state;
    reg [7:0] seq_lo;
    reg [7:0] len_lo;
    reg [7:0] crc_lo;
    reg [8:0] payload_index;

    // Separate clock-only memory write process for RAM inference.
    // Do not reset the entire memory; validity comes from packet_valid.
    (* ram_style = "distributed" *) reg [7:0] payload_mem [0:255];
    assign payload_data = payload_mem[payload_addr];

    wire payload_write = rst_n && (state == S_PAYLOAD) && byte_valid;
    always @(posedge clk) begin
        if (payload_write)
            payload_mem[payload_index[7:0]] <= byte_data;
    end

    wire [15:0] crc_value;
    wire crc_clear = (state == S_SYNC1) || (state == S_SYNC2);
    wire crc_feed = byte_valid &&
        (((state >= S_VERSION) && (state <= S_LEN_HI)) ||
         (state == S_PAYLOAD));

    uart_crc16 u_crc16 (
        .clk(clk),
        .rst_n(rst_n),
        .clear(crc_clear),
        .data_in(byte_data),
        .data_valid(crc_feed),
        .crc_out(crc_value)
    );

    localparam integer TIMER_W =
        (TIMEOUT_CYCLES <= 1) ? 1 : $clog2(TIMEOUT_CYCLES);

    reg [TIMER_W-1:0] timeout_timer;
    wire receiving = (state >= S_VERSION) && (state <= S_CRC_HI);
    wire timeout_expired = receiving && !byte_valid &&
        (timeout_timer == TIMEOUT_CYCLES - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            timeout_timer <= {TIMER_W{1'b0}};
        else if (!receiving || byte_valid || timeout_expired)
            timeout_timer <= {TIMER_W{1'b0}};
        else
            timeout_timer <= timeout_timer + 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_SYNC1;
            packet_valid <= 1'b0;
            packet_type <= 8'd0;
            packet_seq <= 16'd0;
            packet_len <= 9'd0;
            seq_lo <= 8'd0;
            len_lo <= 8'd0;
            crc_lo <= 8'd0;
            payload_index <= 9'd0;
            crc_error_count <= 32'd0;
            format_error_count <= 32'd0;
            timeout_count <= 32'd0;
            busy_drop_count <= 32'd0;
        end else if (state == S_HOLD) begin
            if (byte_valid)
                busy_drop_count <= busy_drop_count + 1'b1;
            if (packet_ready) begin
                packet_valid <= 1'b0;
                state <= S_SYNC1;
            end
        end else if (timeout_expired) begin
            timeout_count <= timeout_count + 1'b1;
            state <= S_SYNC1;
        end else if (byte_valid) begin
            case (state)
                S_SYNC1: begin
                    if (byte_data == 8'hA5)
                        state <= S_SYNC2;
                end
                S_SYNC2: begin
                    if (byte_data == 8'h5A)
                        state <= S_VERSION;
                    else if (byte_data == 8'hA5)
                        state <= S_SYNC2;
                    else
                        state <= S_SYNC1;
                end
                S_VERSION: begin
                    if (byte_data == 8'h01)
                        state <= S_TYPE;
                    else begin
                        format_error_count <= format_error_count + 1'b1;
                        state <= S_SYNC1;
                    end
                end
                S_TYPE: begin
                    packet_type <= byte_data;
                    state <= S_SEQ_LO;
                end
                S_SEQ_LO: begin
                    seq_lo <= byte_data;
                    state <= S_SEQ_HI;
                end
                S_SEQ_HI: begin
                    packet_seq <= {byte_data, seq_lo};
                    state <= S_LEN_LO;
                end
                S_LEN_LO: begin
                    len_lo <= byte_data;
                    state <= S_LEN_HI;
                end
                S_LEN_HI: begin
                    if ({byte_data, len_lo} > 16'd256) begin
                        format_error_count <= format_error_count + 1'b1;
                        state <= S_SYNC1;
                    end else begin
                        packet_len <= {byte_data[0], len_lo};
                        payload_index <= 9'd0;
                        if ({byte_data, len_lo} == 16'd0)
                            state <= S_CRC_LO;
                        else
                            state <= S_PAYLOAD;
                    end
                end
                S_PAYLOAD: begin
                    // Memory write happens in the separate clock-only process.
                    if (payload_index + 9'd1 >= packet_len)
                        state <= S_CRC_LO;
                    else
                        payload_index <= payload_index + 1'b1;
                end
                S_CRC_LO: begin
                    crc_lo <= byte_data;
                    state <= S_CRC_HI;
                end
                S_CRC_HI: begin
                    if ({byte_data, crc_lo} == crc_value) begin
                        packet_valid <= 1'b1;
                        state <= S_HOLD;
                    end else begin
                        crc_error_count <= crc_error_count + 1'b1;
                        state <= S_SYNC1;
                    end
                end
                default: state <= S_SYNC1;
            endcase
        end
    end
endmodule
