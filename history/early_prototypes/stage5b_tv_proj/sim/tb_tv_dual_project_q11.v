`timescale 1ns/1ps
module tb_tv_dual_project_q11;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,start=0;
    reg signed [15:0] vx_in=0,vy_in=0;
    wire ready,valid_out;
    wire signed [15:0] px_out,py_out;
    tv_dual_project_q11 dut(.clk(clk),.rst_n(rst_n),.start(start),
        .vx_in(vx_in),.vy_in(vy_in),.ready(ready),.valid_out(valid_out),
        .px_out(px_out),.py_out(py_out));
    reg [15:0] x_vec[0:127],y_vec[0:127],x_ref[0:127],y_ref[0:127];
    integer i, errors=0, cycles=0, waited;
    initial begin
        #500000; $display("FAIL: global timeout"); $fatal(1);
    end
    initial begin
        $readmemh("input_x.mem",x_vec);
        $readmemh("input_y.mem",y_vec);
        $readmemh("expected_x.mem",x_ref);
        $readmemh("expected_y.mem",y_ref);
        repeat(5) @(negedge clk);rst_n=1;
        for(i=0;i<128;i=i+1) begin
            waited=0;
            @(negedge clk);
            while(ready!==1'b1) begin
                @(negedge clk);waited=waited+1;
                if(waited>200) begin $display("FAIL: ready timeout idx=%0d",i);$fatal(1);end
            end
            vx_in=$signed(x_vec[i]);vy_in=$signed(y_vec[i]);start=1;
            @(negedge clk);start=0;
            waited=0;
            // Sampling on negative clock edges avoids a race with NBA outputs.
            while(valid_out!==1'b1) begin
                @(negedge clk);waited=waited+1;
                if(waited>200) begin $display("FAIL: output timeout idx=%0d",i);$fatal(1);end
            end
            cycles=cycles+waited;
            if(px_out!==$signed(x_ref[i]) || py_out!==$signed(y_ref[i])) begin
                errors=errors+1;
                if(errors<=10) $display("MISMATCH idx=%0d in=(%0d,%0d) out=(%0d,%0d) expected=(%0d,%0d)",
                    i,vx_in,vy_in,px_out,py_out,$signed(x_ref[i]),$signed(y_ref[i]));
            end
        end
        if(errors) begin
            $display("FAIL: %0d mismatches / 128",errors);$fatal(1);
        end
        $display("PASS: isotropic TV dual projection 128 / 128 (Q5.11 integer reference)");
        $display("PASS: zero vector, unit boundary, overflow-edge and random inputs");
        $display("ALL TESTS PASSED: Stage-5B serial TV dual projection RTL");
        $finish;
    end
endmodule
