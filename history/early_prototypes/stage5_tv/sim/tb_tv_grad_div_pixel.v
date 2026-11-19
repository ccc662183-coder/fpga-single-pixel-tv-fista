`timescale 1ns / 1ps
module tb_tv_grad_div_pixel;
    localparam integer W=16,H=16,N=W*H;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, valid_in=0;
    reg [7:0] x_center=0,x_right=0,x_down=0;
    reg signed [11:0] px_center=0,px_left=0,py_center=0,py_up=0;
    reg at_left=0,at_right=0,at_top=0,at_bottom=0;
    wire valid_out;
    wire signed [9:0] grad_x,grad_y;
    wire signed [15:0] divergence;
    reg [7:0] img[0:N-1];
    reg [11:0] px[0:N-1],py[0:N-1];
    reg [9:0] gx_ref[0:N-1],gy_ref[0:N-1];
    reg [15:0] div_ref[0:N-1];
    integer i,r,c,errors=0;
    reg signed [63:0] dot_gp=0, dot_xdiv=0;
    tv_grad_div_pixel dut(.clk(clk),.rst_n(rst_n),.valid_in(valid_in),
        .x_center(x_center),.x_right(x_right),.x_down(x_down),
        .px_center(px_center),.px_left(px_left),.py_center(py_center),.py_up(py_up),
        .at_left(at_left),.at_right(at_right),.at_top(at_top),.at_bottom(at_bottom),
        .valid_out(valid_out),.grad_x(grad_x),.grad_y(grad_y),.divergence(divergence));
    initial begin
        #100000; $display("FAIL: simulation timeout"); $fatal(1);
    end
    initial begin
        $readmemh("tv16_pixels.mem",img);
        $readmemh("tv16_px.mem",px);
        $readmemh("tv16_py.mem",py);
        $readmemh("tv16_expected_gx.mem",gx_ref);
        $readmemh("tv16_expected_gy.mem",gy_ref);
        $readmemh("tv16_expected_div.mem",div_ref);
        repeat(4) @(negedge clk);
        rst_n=1;
        for(i=0;i<N;i=i+1) begin
            r=i/W; c=i%W;
            @(negedge clk);
            valid_in=1;
            x_center=img[i];
            x_right=(c==W-1)?img[i]:img[i+1];
            x_down=(r==H-1)?img[i]:img[i+W];
            px_center=$signed(px[i]);
            px_left=(c==0)?12'sd0:$signed(px[i-1]);
            py_center=$signed(py[i]);
            py_up=(r==0)?12'sd0:$signed(py[i-W]);
            at_left=(c==0);at_right=(c==W-1);
            at_top=(r==0);at_bottom=(r==H-1);
            @(posedge clk);#1;
            if (valid_out!==1'b1 || grad_x!==$signed(gx_ref[i]) ||
                grad_y!==$signed(gy_ref[i]) || divergence!==$signed(div_ref[i])) begin
                errors=errors+1;
                if(errors<=8) $display("MISMATCH idx=%0d valid=%b gx=%0d/%0d gy=%0d/%0d div=%0d/%0d",i,
                    valid_out,grad_x,$signed(gx_ref[i]),grad_y,$signed(gy_ref[i]),
                    divergence,$signed(div_ref[i]));
            end
            dot_gp=dot_gp+$signed(gx_ref[i])*$signed(px[i])+$signed(gy_ref[i])*$signed(py[i]);
            dot_xdiv=dot_xdiv+$signed({1'b0,img[i]})*$signed(div_ref[i]);
        end
        @(negedge clk);valid_in=0;
        @(posedge clk);#1;
        if(valid_out!==1'b0) begin
            $display("FAIL: valid_out did not clear"); $fatal(1);
        end
        if(errors!=0) begin
            $display("FAIL: %0d of 256 pixels mismatched",errors);$fatal(1);
        end
        if(dot_gp+dot_xdiv!=64'sd0) begin
            $display("FAIL: adjoint identity: %0d + %0d != 0",dot_gp,dot_xdiv);$fatal(1);
        end
        $display("PASS: TV forward gradient 256 / 256");
        $display("PASS: TV divergence 256 / 256");
        $display("PASS: discrete adjoint identity");
        $display("ALL TESTS PASSED: Stage-5A TV gradient and divergence RTL");
        $finish;
    end
endmodule
