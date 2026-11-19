
`timescale 1ns / 1ps

// ============================================================
// UART Packet Transmitter
//
// Protocol:
// A5 5A | VERSION | TYPE | SEQ | LEN | PAYLOAD | CRC16
//
// VERSION = 0x01
// SEQ, LEN, CRC: Little-endian
// Payload length: 0..256 bytes
//
// CRC-16/CCITT-FALSE:
// Polynomial = 0x1021
// Initial    = 0xFFFF
// No reflection, no final XOR
//
// The payload source must remain stable until packet_done.
//
// S_WAIT_ARM prevents an earlier UART tx_done pulse from
// being mistaken for the final CRC byte completion.
// ============================================================

module uart_packet_tx (
    input  wire        clk,
    input  wire        rst_n,

    // Packet request
    input  wire        packet_start,
    input  wire [7:0]  packet_type,
    input  wire [15:0] packet_seq,
    input  wire [8:0]  packet_len,

    // External payload memory read interface
    output wire [7:0]  payload_addr,
    input  wire [7:0]  payload_data,

    // Byte stream to UART TX
    output reg  [7:0]  tx_data,
    output wire        tx_valid,
    input  wire        tx_ready,
    input  wire        tx_done,

    // Packet status
    output wire        packet_busy,
    output reg         packet_done,
    output reg         invalid_len
);

    // ========================================================
    // 1. State definitions
    // ========================================================

    localparam [2:0]
        S_IDLE      = 3'd0,
        S_HEADER    = 3'd1,
        S_PAYLOAD   = 3'd2,
        S_CRC_LO    = 3'd3,
        S_CRC_HI    = 3'd4,
        S_WAIT_ARM  = 3'd5,
        S_WAIT_DONE = 3'd6;

    reg [2:0] state;

    // Latched packet information
    reg [7:0]  type_reg;
    reg [15:0] seq_reg;
    reg [8:0]  len_reg;

    reg [2:0] header_index;
    reg [8:0] payload_index;

    reg [15:0] crc_reg;

    // ========================================================
    // 2. CRC16 update function
    // ========================================================

    function [15:0] crc16_next;
        input [15:0] crc_current;
        input [7:0]  data_byte;

        reg [15:0] crc_temp;
        integer i;

        begin

            crc_temp = crc_current ^
                       {data_byte, 8'h00};

            for (i = 0; i < 8; i = i + 1) begin

                if (crc_temp[15])
                    crc_temp =
                        (crc_temp << 1) ^ 16'h1021;
                else
                    crc_temp = crc_temp << 1;

            end

            crc16_next = crc_temp;

        end
    endfunction

    // ========================================================
    // 3. Status and handshake
    // ========================================================

    assign packet_busy = (state != S_IDLE);

    assign tx_valid =
        rst_n &&
        (
            (state == S_HEADER)  ||
            (state == S_PAYLOAD) ||
            (state == S_CRC_LO)  ||
            (state == S_CRC_HI)
        );

    wire tx_accept;

    assign tx_accept = tx_valid && tx_ready;

    // Payload address is valid in S_PAYLOAD.
    // The payload memory uses an asynchronous read interface.

    assign payload_addr =
        (state == S_PAYLOAD) ?
        payload_index[7:0] : 8'd0;

    // ========================================================
    // 4. Output byte selection
    // ========================================================

    always @(*) begin

        tx_data = 8'h00;

        case (state)

            // ------------------------------------------------
            // Header: 8 bytes
            // ------------------------------------------------

            S_HEADER: begin

                case (header_index)

                    3'd0:
                        tx_data = 8'hA5;

                    3'd1:
                        tx_data = 8'h5A;

                    3'd2:
                        tx_data = 8'h01;

                    3'd3:
                        tx_data = type_reg;

                    3'd4:
                        tx_data = seq_reg[7:0];

                    3'd5:
                        tx_data = seq_reg[15:8];

                    3'd6:
                        tx_data = len_reg[7:0];

                    3'd7:
                        tx_data = {7'd0, len_reg[8]};

                    default:
                        tx_data = 8'h00;

                endcase

            end

            // ------------------------------------------------
            // Payload data
            // ------------------------------------------------

            S_PAYLOAD: begin
                tx_data = payload_data;
            end

            // ------------------------------------------------
            // CRC low byte
            // ------------------------------------------------

            S_CRC_LO: begin
                tx_data = crc_reg[7:0];
            end

            // ------------------------------------------------
            // CRC high byte
            // ------------------------------------------------

            S_CRC_HI: begin
                tx_data = crc_reg[15:8];
            end

            default: begin
                tx_data = 8'h00;
            end

        endcase

    end

    // ========================================================
    // 5. Packet transmission state machine
    // ========================================================

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            state         <= S_IDLE;

            type_reg      <= 8'd0;
            seq_reg       <= 16'd0;
            len_reg       <= 9'd0;

            header_index  <= 3'd0;
            payload_index <= 9'd0;

            crc_reg       <= 16'hFFFF;

            packet_done   <= 1'b0;
            invalid_len   <= 1'b0;

        end
        else begin

            // Status outputs are one-clock pulses.
            packet_done <= 1'b0;
            invalid_len <= 1'b0;

            case (state)

                // ============================================
                // IDLE
                // Accept a new packet request
                // ============================================

                S_IDLE: begin

                    if (packet_start) begin

                        if (packet_len > 9'd256) begin

                            invalid_len <= 1'b1;

                        end
                        else begin

                            type_reg <= packet_type;
                            seq_reg  <= packet_seq;
                            len_reg  <= packet_len;

                            header_index  <= 3'd0;
                            payload_index <= 9'd0;

                            crc_reg <= 16'hFFFF;

                            state <= S_HEADER;

                        end

                    end

                end

                // ============================================
                // HEADER
                // Send the 8 header bytes
                // ============================================

                S_HEADER: begin

                    if (tx_accept) begin

                        // The first two bytes are synchronization
                        // markers and are not included in CRC.

                        if (header_index >= 3'd2) begin

                            crc_reg <= crc16_next(
                                crc_reg,
                                tx_data
                            );

                        end

                        if (header_index == 3'd7) begin

                            if (len_reg == 9'd0) begin

                                state <= S_CRC_LO;

                            end
                            else begin

                                payload_index <= 9'd0;
                                state <= S_PAYLOAD;

                            end

                        end
                        else begin

                            header_index <=
                                header_index + 1'b1;

                        end

                    end

                end

                // ============================================
                // PAYLOAD
                // Send payload bytes
                // ============================================

                S_PAYLOAD: begin

                    if (tx_accept) begin

                        crc_reg <= crc16_next(
                            crc_reg,
                            tx_data
                        );

                        if (payload_index ==
                            len_reg - 9'd1) begin

                            state <= S_CRC_LO;

                        end
                        else begin

                            payload_index <=
                                payload_index + 1'b1;

                        end

                    end

                end

                // ============================================
                // CRC_LO
                // Send low CRC byte
                // ============================================

                S_CRC_LO: begin

                    if (tx_accept) begin

                        state <= S_CRC_HI;

                    end

                end

                // ============================================
                // CRC_HI
                // Send high CRC byte
                // ============================================

                S_CRC_HI: begin

                    if (tx_accept) begin

                        // The final CRC byte was accepted,
                        // but UART transmission may still
                        // be in progress.

                        state <= S_WAIT_ARM;

                    end

                end

                // ============================================
                // WAIT_ARM
                //
                // Ignore a tx_done pulse that may belong to
                // the previous UART byte.
                //
                // Wait until tx_done becomes low before
                // monitoring final-byte completion.
                // ============================================

                S_WAIT_ARM: begin

                    if (!tx_done) begin

                        state <= S_WAIT_DONE;

                    end

                end

                // ============================================
                // WAIT_DONE
                //
                // The last CRC byte must finish its actual
                // UART frame before packet_done is asserted.
                // ============================================

                S_WAIT_DONE: begin

                    if (tx_done) begin

                        packet_done <= 1'b1;

                        state <= S_IDLE;

                    end

                end

                // ============================================
                // Recovery from invalid state
                // ============================================

                default: begin

                    state <= S_IDLE;

                end

            endcase

        end

    end

endmodule

