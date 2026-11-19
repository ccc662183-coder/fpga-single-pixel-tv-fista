`timescale 1ns / 1ps
module tb_fwht_q11_stage2;
    localparam integer LG = 12;
    localparam integer N  = (1 << LG);

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg ext_we = 1'b0;
    reg [LG-1:0] ext_addr = {LG{1'b0}};
    reg signed [31:0] ext_wdata_s32 = 32'sd0;

    wire ready;
    wire done;
    wire signed [31:0] ext_rdata_raw_s32;
    wire signed [31:0] ext_rdata_norm_s32;

    reg signed [15:0] input_q11 [0:N-1];
    reg signed [31:0] expected_raw [0:N-1];
    reg signed [31:0] expected_norm [0:N-1];

    integer i;
    integer cycles;
    integer errors_raw;
    integer errors_norm;
    integer sum_raw;
    integer sum_norm;
    integer min_raw;
    integer max_raw;
    integer min_norm;
    integer max_norm;

    fwht_q11_stage2 #(.LOG2_POINTS(LG)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .ready(ready),
        .done(done),
        .ext_we(ext_we),
        .ext_addr(ext_addr),
        .ext_wdata_s32(ext_wdata_s32),
        .ext_rdata_raw_s32(ext_rdata_raw_s32),
        .ext_rdata_norm_s32(ext_rdata_norm_s32)
    );

    initial begin
        #50000000;
        $display("FAIL: global simulation timeout");
        $fatal(1);
    end

    initial begin
        $readmemh("cat64_input_q11_s16.mem", input_q11);
        $readmemh("cat64_fwht_raw_q11_s32.mem", expected_raw);
        $readmemh("cat64_fwht_normalized_q11_s32.mem", expected_norm);

        repeat (6) @(negedge clk);
        rst_n = 1'b1;

        // Load 4096 signed Q5.11 pixels into the 32-bit FWHT work memory.
        for (i = 0; i < N; i = i + 1) begin
            @(negedge clk);
            ext_we = 1'b1;
            ext_addr = i[LG-1:0];
            ext_wdata_s32 = {{16{input_q11[i][15]}}, input_q11[i]};
        end

        @(negedge clk);
        ext_we = 1'b0;
        ext_addr = {LG{1'b0}};

        if (ready !== 1'b1) begin
            $display("FAIL: FWHT core not ready after input loading");
            $fatal(1);
        end

        // Execute one unnormalized H_4096 transform.
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        cycles = 0;
        while (done !== 1'b1) begin
            @(negedge clk);
            cycles = cycles + 1;
            if (cycles > 150000) begin
                $display("FAIL: FWHT exceeded 150000 clocks");
                $fatal(1);
            end
        end

        if (ready !== 1'b1) begin
            $display("FAIL: FWHT core did not return to ready");
            $fatal(1);
        end

        errors_raw = 0;
        errors_norm = 0;
        sum_raw = 0;
        sum_norm = 0;
        min_raw = 2147483647;
        max_raw = -2147483647;
        min_norm = 2147483647;
        max_norm = -2147483647;

        // The core read port is synchronous: address is applied before posedge.
        for (i = 0; i < N; i = i + 1) begin
            @(negedge clk);
            ext_we = 1'b0;
            ext_addr = i[LG-1:0];

            @(posedge clk);
            #1;

            sum_raw = sum_raw + $signed(ext_rdata_raw_s32);
            sum_norm = sum_norm + $signed(ext_rdata_norm_s32);

            if ($signed(ext_rdata_raw_s32) < min_raw) min_raw = $signed(ext_rdata_raw_s32);
            if ($signed(ext_rdata_raw_s32) > max_raw) max_raw = $signed(ext_rdata_raw_s32);
            if ($signed(ext_rdata_norm_s32) < min_norm) min_norm = $signed(ext_rdata_norm_s32);
            if ($signed(ext_rdata_norm_s32) > max_norm) max_norm = $signed(ext_rdata_norm_s32);

            if (ext_rdata_raw_s32 !== expected_raw[i]) begin
                errors_raw = errors_raw + 1;
                if (errors_raw <= 10)
                    $display("RAW MISMATCH addr=%0d got=%0d expected=%0d",
                             i, $signed(ext_rdata_raw_s32), $signed(expected_raw[i]));
            end

            if (ext_rdata_norm_s32 !== expected_norm[i]) begin
                errors_norm = errors_norm + 1;
                if (errors_norm <= 10)
                    $display("NORM MISMATCH addr=%0d got=%0d expected=%0d",
                             i, $signed(ext_rdata_norm_s32), $signed(expected_norm[i]));
            end
        end

        if (errors_raw != 0 || errors_norm != 0) begin
            $display("FAIL: raw errors=%0d normalized errors=%0d", errors_raw, errors_norm);
            $fatal(1);
        end

        if (sum_raw != 4177920 || min_raw != -163469 || max_raw != 3930619) begin
            $display("FAIL: raw checksum/range mismatch sum=%0d range=[%0d,%0d]",
                     sum_raw, min_raw, max_raw);
            $fatal(1);
        end

        if (sum_norm != 63238 || min_norm != -2555 || max_norm != 61415) begin
            $display("FAIL: normalized checksum/range mismatch sum=%0d range=[%0d,%0d]",
                     sum_norm, min_norm, max_norm);
            $fatal(1);
        end

        $display("PASS: raw FWHT 4096/4096 exact, signed S32.F11");
        $display("PASS: normalized FWHT 4096/4096 exact, arithmetic >>> 6");
        $display("PASS: raw range=[%0d,%0d], sum=%0d", min_raw, max_raw, sum_raw);
        $display("PASS: normalized range=[%0d,%0d], sum=%0d", min_norm, max_norm, sum_norm);
        $display("PASS: compute cycles=%0d", cycles);
        $display("ALL TESTS PASSED: Stage-2A Q5.11 FWHT adapter");
        $finish;
    end
endmodule
