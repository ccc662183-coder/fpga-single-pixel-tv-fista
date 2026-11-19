
`timescale 1ns / 1ps

module uart_crc16 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,
    input  wire [7:0]  data_in,
    input  wire        data_valid,

    output reg [15:0]  crc_out
);

    // CRC-16/CCITT-FALSE
    // Polynomial: 0x1021
    // Initial value: 0xFFFF
    // No reflection, no final XOR

    function [15:0] crc16_next;
        input [15:0] crc_current;
        input [7:0]  data_byte;

        reg [15:0] crc_temp;
        integer i;

        begin
            crc_temp =
                crc_current ^ {data_byte, 8'h00};

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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            crc_out <= 16'hFFFF;
        else if (clear)
            crc_out <= 16'hFFFF;
        else if (data_valid)
            crc_out <= crc16_next(
                crc_out, data_in
            );
    end

endmodule

