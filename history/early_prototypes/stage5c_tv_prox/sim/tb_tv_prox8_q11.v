`timescale 1ns/1ps
module tb_tv_prox8_q11;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,load_we=0,start=0;
    reg [5:0] load_addr=0,read_addr=0;
    reg signed [15:0] load_data=0;
    wire signed [15:0] read_data;
    wire ready,done;
    tv_prox8_q11 dut(.clk(clk),.rst_n(rst_n),.load_we(load_we),
         .load_addr(load_addr),.load_data(load_data),.start(start),
         .ready(ready),.done(done),.read_addr(read_addr),.read_data(read_data));
    reg [15:0] input_vec [0:63];
    reg [15:0] expected_vec [0:63];
    integer i,err=0,cycles=0,sum=0;
    initial begin #2000000; $display("FAIL: global TV prox timeout"); $fatal(1); end
    initial begin
        $readmemh("input_pixels.mem",input_vec);
        $readmemh("expected_prox.mem",expected_vec);
        repeat(6) @(negedge clk);
        rst_n=1;
        for(i=0;i<64;i=i+1) begin
            @(negedge clk);
            load_we=1;
            load_addr=i;
            load_data=$signed(input_vec[i]);
        end
        @(negedge clk);load_we=0;
        if(ready!==1'b1) begin $display("FAIL: not ready");$fatal(1);end
        start=1;
        @(negedge clk);start=0;
        cycles=0;
        while(done!==1'b1) begin
            @(negedge clk);
            cycles=cycles+1;
            if(cycles>180000) begin $display("FAIL: calculation exceeded 180000 clocks");$fatal(1);end
        end
        for(i=0;i<64;i=i+1) begin
            read_addr=i;
            #1;
            sum=sum+$signed(read_data);
            if(read_data!==$signed(expected_vec[i])) begin
                err=err+1;
                if(err<11) $display("MISMATCH at %0d: got %0d, expected %0d",i,read_data,$signed(expected_vec[i]));
            end
        end
        if(err) begin $display("FAIL: %0d mismatch values / 64",err);$fatal(1);end
        $display("PASS: 8x8 fixed-point TV prox 64 / 64 values");
        $display("PASS: 3 sequential Jacobi dual iterations and Q5.11 nonlinear projection");
        $display("PASS: sum=%0d, cycles=%0d",sum,cycles);
        $display("ALL TESTS PASSED: Stage-5C integrated TV inner-loop RTL");
        $finish;
    end
endmodule
