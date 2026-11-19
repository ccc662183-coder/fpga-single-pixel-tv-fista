`timescale 1ns / 1ps
module tb_fwht_inplace;
    localparam integer LG=12;
    localparam integer N=(1 << LG);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, start=0, ext_we=0;
    reg [LG-1:0] ext_addr=0;
    reg signed [31:0] ext_wdata=0;
    wire signed [31:0] ext_rdata;
    wire ready, done;
    reg signed [31:0] input_vec [0:N-1];
    reg signed [31:0] expected_vec [0:N-1];
    integer i, err_forward=0, err_roundtrip=0;
    reg signed [31:0] expected_back;
    fwht_inplace #(.LOG2_POINTS(LG),.DATA_WIDTH(32)) dut (
        .clk(clk),.rst_n(rst_n),.start(start),.ready(ready),.done(done),
        .ext_we(ext_we),.ext_addr(ext_addr),.ext_wdata(ext_wdata),
        .ext_rdata(ext_rdata)
    );
    initial begin
        #50000000;
        $display("FAIL: SIMULATION TIMEOUT");
        $fatal(1);
    end
    initial begin
        $readmemh("fwht64_input.mem",input_vec);
        $readmemh("fwht64_expected.mem",expected_vec);
        repeat(5) @(negedge clk);
        rst_n=1;
        // Write all 4096 32-bit input samples through external port.
        for(i=0;i<N;i=i+1) begin
            @(negedge clk);
            ext_we=1;
            ext_addr=i;
            ext_wdata=input_vec[i];
        end
        @(negedge clk);
        ext_we=0;
        ext_addr=0;
        if (!ready) begin
            $display("FAIL: not ready before start"); $fatal(1);
        end
        start=1;
        @(negedge clk);
        start=0;
        @(posedge done);
        @(negedge clk);
        if (!ready) begin $display("FAIL: not ready after forward"); $fatal(1); end
        for(i=0;i<N;i=i+1) begin
            @(negedge clk);
            ext_addr=i;
            @(posedge clk);
            #1;
            if (ext_rdata !== expected_vec[i]) begin
                err_forward=err_forward+1;
                if (err_forward <= 10)
                    $display("FORWARD MISMATCH %0d: got %0d expected %0d",i,ext_rdata,expected_vec[i]);
            end
        end
        if (err_forward!=0) begin
            $display("FAIL: forward %0d errors",err_forward); $fatal(1);
        end
        $display("PASS: forward 4096 / 4096");
        @(negedge clk); start=1;
        @(negedge clk); start=0;
        @(posedge done);
        @(negedge clk);
        for(i=0;i<N;i=i+1) begin
            @(negedge clk);
            ext_addr=i;
            @(posedge clk);
            #1;
            expected_back=input_vec[i]*N;
            if (ext_rdata !== expected_back) begin
                err_roundtrip=err_roundtrip+1;
                if (err_roundtrip <= 10)
                    $display("ROUNDTRIP MISMATCH %0d: got %0d expected %0d",i,ext_rdata,expected_back);
            end
        end
        if (err_roundtrip!=0) begin
            $display("FAIL: roundtrip %0d errors",err_roundtrip); $fatal(1);
        end
        $display("PASS: roundtrip 4096 / 4096");
        $display("ALL TESTS PASSED: Stage-4 integer FWHT core functional simulation");
        $finish;
    end
endmodule
